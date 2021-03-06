{ config, lib, pkgs, utils, ... }:

with utils;
with lib;

let

  cfg = config.networking;
  interfaces = attrValues cfg.interfaces;

  slaves = concatMap (i: i.interfaces) (attrValues cfg.bonds)
    ++ concatMap (i: i.interfaces) (attrValues cfg.bridges)
    ++ concatMap (i: i.interfaces) (attrValues cfg.vswitches)
    ++ concatMap (i: [i.interface]) (attrValues cfg.macvlans)
    ++ concatMap (i: [i.interface]) (attrValues cfg.vlans);

  # We must escape interfaces due to the systemd interpretation
  subsystemDevice = interface:
    "sys-subsystem-net-devices-${escapeSystemdPath interface}.device";

  interfaceIps = i:
    i.ipv4.addresses
    ++ optionals cfg.enableIPv6 i.ipv6.addresses;

  destroyBond = i: ''
    while true; do
      UPDATED=1
      SLAVES=$(ip link | grep 'master ${i}' | awk -F: '{print $2}')
      for I in $SLAVES; do
        UPDATED=0
        ip link set "$I" nomaster
      done
      [ "$UPDATED" -eq "1" ] && break
    done
    ip link set "${i}" down 2>/dev/null || true
    ip link del "${i}" 2>/dev/null || true
  '';

  # warn that these attributes are deprecated (2017-2-2)
  # Should be removed in the release after next
  bondDeprecation = rec {
    deprecated = [ "lacp_rate" "miimon" "mode" "xmit_hash_policy" ];
    filterDeprecated = bond: (filterAttrs (attrName: attr:
                         elem attrName deprecated && attr != null) bond);
  };

  bondWarnings =
    let oneBondWarnings = bondName: bond:
          mapAttrsToList (bondText bondName) (bondDeprecation.filterDeprecated bond);
        bondText = bondName: optName: _:
          "${bondName}.${optName} is deprecated, use ${bondName}.driverOptions";
    in {
      warnings = flatten (mapAttrsToList oneBondWarnings cfg.bonds);
    };

  normalConfig = {

    systemd.services =
      let

        deviceDependency = dev:
          # Use systemd service if we manage device creation, else
          # trust udev when not in a container
          if (hasAttr dev (filterAttrs (k: v: v.virtual) cfg.interfaces)) ||
             (hasAttr dev cfg.bridges) ||
             (hasAttr dev cfg.bonds) ||
             (hasAttr dev cfg.macvlans) ||
             (hasAttr dev cfg.sits) ||
             (hasAttr dev cfg.vlans) ||
             (hasAttr dev cfg.vswitches)
          then [ "${dev}-netdev.service" ]
          else optional (dev != null && dev != "lo" && !config.boot.isContainer) (subsystemDevice dev);

        hasDefaultGatewaySet = (cfg.defaultGateway != null && cfg.defaultGateway.address != "")
                            || (cfg.enableIPv6 && cfg.defaultGateway6 != null && cfg.defaultGateway6.address != "");

        networkLocalCommands = {
          after = [ "network-setup.service" ];
          bindsTo = [ "network-setup.service" ];
        };

        networkSetup =
          { description = "Networking Setup";

            after = [ "network-pre.target" "systemd-udevd.service" "systemd-sysctl.service" ];
            before = [ "network.target" "shutdown.target" ];
            wants = [ "network.target" ];
            partOf = map (i: "network-addresses-${i.name}.service") interfaces;
            conflicts = [ "shutdown.target" ];
            wantedBy = [ "multi-user.target" ] ++ optional hasDefaultGatewaySet "network-online.target";

            unitConfig.ConditionCapability = "CAP_NET_ADMIN";

            path = [ pkgs.iproute ];

            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };

            unitConfig.DefaultDependencies = false;

            script =
              ''
                # Set the static DNS configuration, if given.
                ${pkgs.openresolv}/sbin/resolvconf -m 1 -a static <<EOF
                ${optionalString (cfg.nameservers != [] && cfg.domain != null) ''
                  domain ${cfg.domain}
                ''}
                ${optionalString (cfg.search != []) ("search " + concatStringsSep " " cfg.search)}
                ${flip concatMapStrings cfg.nameservers (ns: ''
                  nameserver ${ns}
                '')}
                EOF

                # Set the default gateway.
                ${optionalString (cfg.defaultGateway != null && cfg.defaultGateway.address != "") ''
                  ${optionalString (cfg.defaultGateway.interface != null) ''
                    ip route replace ${cfg.defaultGateway.address} dev ${cfg.defaultGateway.interface} ${optionalString (cfg.defaultGateway.metric != null)
                      "metric ${toString cfg.defaultGateway.metric}"
                    } proto static
                  ''}
                  ip route replace default ${optionalString (cfg.defaultGateway.metric != null)
                      "metric ${toString cfg.defaultGateway.metric}"
                    } via "${cfg.defaultGateway.address}" ${
                    optionalString (cfg.defaultGatewayWindowSize != null)
                      "window ${toString cfg.defaultGatewayWindowSize}"} ${
                    optionalString (cfg.defaultGateway.interface != null)
                      "dev ${cfg.defaultGateway.interface}"} proto static
                ''}
                ${optionalString (cfg.defaultGateway6 != null && cfg.defaultGateway6.address != "") ''
                  ${optionalString (cfg.defaultGateway6.interface != null) ''
                    ip -6 route replace ${cfg.defaultGateway6.address} dev ${cfg.defaultGateway6.interface} ${optionalString (cfg.defaultGateway6.metric != null)
                      "metric ${toString cfg.defaultGateway6.metric}"
                    } proto static
                  ''}
                  ip -6 route replace default ${optionalString (cfg.defaultGateway6.metric != null)
                      "metric ${toString cfg.defaultGateway6.metric}"
                    } via "${cfg.defaultGateway6.address}" ${
                    optionalString (cfg.defaultGatewayWindowSize != null)
                      "window ${toString cfg.defaultGatewayWindowSize}"} ${
                    optionalString (cfg.defaultGateway6.interface != null)
                      "dev ${cfg.defaultGateway6.interface}"} proto static
                ''}
              '';
          };

        # For each interface <foo>, create a job ???network-addresses-<foo>.service"
        # that performs static address configuration.  It has a "wants"
        # dependency on ???<foo>.service???, which is supposed to create
        # the interface and need not exist (i.e. for hardware
        # interfaces).  It has a binds-to dependency on the actual
        # network device, so it only gets started after the interface
        # has appeared, and it's stopped when the interface
        # disappears.
        configureAddrs = i:
          let
            ips = interfaceIps i;
          in
          nameValuePair "network-addresses-${i.name}"
          { description = "Address configuration of ${i.name}";
            wantedBy = [
              "network-setup.service"
              "network-link-${i.name}.service"
              "network.target"
            ];
            # order before network-setup because the routes that are configured
            # there may need ip addresses configured
            before = [ "network-setup.service" ];
            bindsTo = deviceDependency i.name;
            after = [ "network-pre.target" ] ++ (deviceDependency i.name);
            serviceConfig.Type = "oneshot";
            serviceConfig.RemainAfterExit = true;
            # Restart rather than stop+start this unit to prevent the
            # network from dying during switch-to-configuration.
            stopIfChanged = false;
            path = [ pkgs.iproute ];
            script =
              ''
                state="/run/nixos/network/addresses/${i.name}"
                mkdir -p $(dirname "$state")

                ${flip concatMapStrings ips (ip:
                  let
                    cidr = "${ip.address}/${toString ip.prefixLength}";
                  in
                  ''
                    echo "${cidr}" >> $state
                    echo -n "adding address ${cidr}... "
                    if out=$(ip addr add "${cidr}" dev "${i.name}" 2>&1); then
                      echo "done"
                    elif ! echo "$out" | grep "File exists" >/dev/null 2>&1; then
                      echo "'ip addr add "${cidr}" dev "${i.name}"' failed: $out"
                      exit 1
                    fi
                  ''
                )}

                state="/run/nixos/network/routes/${i.name}"
                mkdir -p $(dirname "$state")

                ${flip concatMapStrings (i.ipv4.routes ++ i.ipv6.routes) (route:
                  let
                    cidr = "${route.address}/${toString route.prefixLength}";
                    via = optionalString (route.via != null) ''via "${route.via}"'';
                    options = concatStrings (mapAttrsToList (name: val: "${name} ${val} ") route.options);
                  in
                  ''
                     echo "${cidr}" >> $state
                     echo -n "adding route ${cidr}... "
                     if out=$(ip route add "${cidr}" ${options} ${via} dev "${i.name}" proto static 2>&1); then
                       echo "done"
                     elif ! echo "$out" | grep "File exists" >/dev/null 2>&1; then
                       echo "'ip route add "${cidr}" ${options} ${via} dev "${i.name}"' failed: $out"
                       exit 1
                     fi
                  ''
                )}
              '';
            preStop = ''
              state="/run/nixos/network/routes/${i.name}"
              while read cidr; do
                echo -n "deleting route $cidr... "
                ip route del "$cidr" dev "${i.name}" >/dev/null 2>&1 && echo "done" || echo "failed"
              done < "$state"
              rm -f "$state"

              state="/run/nixos/network/addresses/${i.name}"
              while read cidr; do
                echo -n "deleting address $cidr... "
                ip addr del "$cidr" dev "${i.name}" >/dev/null 2>&1 && echo "done" || echo "failed"
              done < "$state"
              rm -f "$state"
            '';
          };

        createTunDevice = i: nameValuePair "${i.name}-netdev"
          { description = "Virtual Network Interface ${i.name}";
            bindsTo = [ "dev-net-tun.device" ];
            after = [ "dev-net-tun.device" "network-pre.target" ];
            wantedBy = [ "network-setup.service" (subsystemDevice i.name) ];
            partOf = [ "network-setup.service" ];
            before = [ "network-setup.service" ];
            path = [ pkgs.iproute ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              ip tuntap add dev "${i.name}" mode "${i.virtualType}" user "${i.virtualOwner}"
            '';
            postStop = ''
              ip link del ${i.name} || true
            '';
          };

        createBridgeDevice = n: v: nameValuePair "${n}-netdev"
          (let
            deps = concatLists (map deviceDependency v.interfaces);
          in
          { description = "Bridge Interface ${n}";
            wantedBy = [ "network-setup.service" (subsystemDevice n) ];
            bindsTo = deps ++ optional v.rstp "mstpd.service";
            partOf = [ "network-setup.service" ] ++ optional v.rstp "mstpd.service";
            after = [ "network-pre.target" ] ++ deps ++ optional v.rstp "mstpd.service"
              ++ concatMap (i: [ "network-addresses-${i}.service" "network-link-${i}.service" ]) v.interfaces;
            before = [ "network-setup.service" ];
            serviceConfig.Type = "oneshot";
            serviceConfig.RemainAfterExit = true;
            path = [ pkgs.iproute ];
            script = ''
              # Remove Dead Interfaces
              echo "Removing old bridge ${n}..."
              ip link show "${n}" >/dev/null 2>&1 && ip link del "${n}"

              echo "Adding bridge ${n}..."
              ip link add name "${n}" type bridge

              # Enslave child interfaces
              ${flip concatMapStrings v.interfaces (i: ''
                ip link set "${i}" master "${n}"
                ip link set "${i}" up
              '')}
              # Save list of enslaved interfaces
              echo "${flip concatMapStrings v.interfaces (i: ''
                ${i}
              '')}" > /run/${n}.interfaces

              ${optionalString config.virtualisation.libvirtd.enable ''
                  # Enslave dynamically added interfaces which may be lost on nixos-rebuild
                  for uri in qemu:///system lxc:///; do
                    for dom in $(${pkgs.libvirt}/bin/virsh -c $uri list --name); do
                      ${pkgs.libvirt}/bin/virsh -c $uri dumpxml "$dom" | \
                      ${pkgs.xmlstarlet}/bin/xmlstarlet sel -t -m "//domain/devices/interface[@type='bridge'][source/@bridge='${n}'][target/@dev]" -v "concat('ip link set ',target/@dev,' master ',source/@bridge,';')" | \
                      ${pkgs.bash}/bin/bash
                    done
                  done
                ''}

              # Enable stp on the interface
              ${optionalString v.rstp ''
                echo 2 >/sys/class/net/${n}/bridge/stp_state
              ''}

              ip link set "${n}" up
            '';
            postStop = ''
              ip link set "${n}" down || true
              ip link del "${n}" || true
              rm -f /run/${n}.interfaces
            '';
            reload = ''
              # Un-enslave child interfaces (old list of interfaces)
              for interface in `cat /run/${n}.interfaces`; do
                ip link set "$interface" nomaster up
              done

              # Enslave child interfaces (new list of interfaces)
              ${flip concatMapStrings v.interfaces (i: ''
                ip link set "${i}" master "${n}"
                ip link set "${i}" up
              '')}
              # Save list of enslaved interfaces
              echo "${flip concatMapStrings v.interfaces (i: ''
                ${i}
              '')}" > /run/${n}.interfaces

              # (Un-)set stp on the bridge
              echo ${if v.rstp then "2" else "0"} > /sys/class/net/${n}/bridge/stp_state
            '';
            reloadIfChanged = true;
          });

        createVswitchDevice = n: v: nameValuePair "${n}-netdev"
          (let
            deps = concatLists (map deviceDependency v.interfaces);
            ofRules = pkgs.writeText "vswitch-${n}-openFlowRules" v.openFlowRules;
          in
          { description = "Open vSwitch Interface ${n}";
            wantedBy = [ "network-setup.service" "vswitchd.service" ] ++ deps;
            bindsTo =  [ "vswitchd.service" (subsystemDevice n) ] ++ deps;
            partOf = [ "network-setup.service" "vswitchd.service" ];
            after = [ "network-pre.target" "vswitchd.service" ] ++ deps;
            before = [ "network-setup.service" ];
            serviceConfig.Type = "oneshot";
            serviceConfig.RemainAfterExit = true;
            path = [ pkgs.iproute config.virtualisation.vswitch.package ];
            script = ''
              echo "Removing old Open vSwitch ${n}..."
              ovs-vsctl --if-exists del-br ${n}

              echo "Adding Open vSwitch ${n}..."
              ovs-vsctl -- add-br ${n} ${concatMapStrings (i: " -- add-port ${n} ${i}") v.interfaces} \
                ${concatMapStrings (x: " -- set-controller ${n} " + x)  v.controllers} \
                ${concatMapStrings (x: " -- " + x) (splitString "\n" v.extraOvsctlCmds)}

              echo "Adding OpenFlow rules for Open vSwitch ${n}..."
              ovs-ofctl add-flows ${n} ${ofRules}
            '';
            postStop = ''
              ip link set ${n} down || true
              ovs-ofctl del-flows ${n} || true
              ovs-vsctl --if-exists del-br ${n}
            '';
          });

        createBondDevice = n: v: nameValuePair "${n}-netdev"
          (let
            deps = concatLists (map deviceDependency v.interfaces);
          in
          { description = "Bond Interface ${n}";
            wantedBy = [ "network-setup.service" (subsystemDevice n) ];
            bindsTo = deps;
            partOf = [ "network-setup.service" ];
            after = [ "network-pre.target" ] ++ deps
              ++ concatMap (i: [ "network-addresses-${i}.service" "network-link-${i}.service" ]) v.interfaces;
            before = [ "network-setup.service" ];
            serviceConfig.Type = "oneshot";
            serviceConfig.RemainAfterExit = true;
            path = [ pkgs.iproute pkgs.gawk ];
            script = ''
              echo "Destroying old bond ${n}..."
              ${destroyBond n}

              echo "Creating new bond ${n}..."
              ip link add name "${n}" type bond \
              ${let opts = (mapAttrs (const toString)
                             (bondDeprecation.filterDeprecated v))
                           // v.driverOptions;
                 in concatStringsSep "\n"
                      (mapAttrsToList (set: val: "  ${set} ${val} \\") opts)}

              # !!! There must be a better way to wait for the interface
              while [ ! -d "/sys/class/net/${n}" ]; do sleep 0.1; done;

              # Bring up the bond and enslave the specified interfaces
              ip link set "${n}" up
              ${flip concatMapStrings v.interfaces (i: ''
                ip link set "${i}" down
                ip link set "${i}" master "${n}"
              '')}
            '';
            postStop = destroyBond n;
          });

        createMacvlanDevice = n: v: nameValuePair "${n}-netdev"
          (let
            deps = deviceDependency v.interface;
          in
          { description = "Vlan Interface ${n}";
            wantedBy = [ "network-setup.service" (subsystemDevice n) ];
            bindsTo = deps;
            partOf = [ "network-setup.service" ];
            after = [ "network-pre.target" ] ++ deps;
            before = [ "network-setup.service" ];
            serviceConfig.Type = "oneshot";
            serviceConfig.RemainAfterExit = true;
            path = [ pkgs.iproute ];
            script = ''
              # Remove Dead Interfaces
              ip link show "${n}" >/dev/null 2>&1 && ip link delete "${n}"
              ip link add link "${v.interface}" name "${n}" type macvlan \
                ${optionalString (v.mode != null) "mode ${v.mode}"}
              ip link set "${n}" up
            '';
            postStop = ''
              ip link delete "${n}" || true
            '';
          });

        createSitDevice = n: v: nameValuePair "${n}-netdev"
          (let
            deps = deviceDependency v.dev;
          in
          { description = "6-to-4 Tunnel Interface ${n}";
            wantedBy = [ "network-setup.service" (subsystemDevice n) ];
            bindsTo = deps;
            partOf = [ "network-setup.service" ];
            after = [ "network-pre.target" ] ++ deps;
            before = [ "network-setup.service" ];
            serviceConfig.Type = "oneshot";
            serviceConfig.RemainAfterExit = true;
            path = [ pkgs.iproute ];
            script = ''
              # Remove Dead Interfaces
              ip link show "${n}" >/dev/null 2>&1 && ip link delete "${n}"
              ip link add name "${n}" type sit \
                ${optionalString (v.remote != null) "remote \"${v.remote}\""} \
                ${optionalString (v.local != null) "local \"${v.local}\""} \
                ${optionalString (v.ttl != null) "ttl ${toString v.ttl}"} \
                ${optionalString (v.dev != null) "dev \"${v.dev}\""}
              ip link set "${n}" up
            '';
            postStop = ''
              ip link delete "${n}" || true
            '';
          });

        createVlanDevice = n: v: nameValuePair "${n}-netdev"
          (let
            deps = deviceDependency v.interface;
          in
          { description = "Vlan Interface ${n}";
            wantedBy = [ "network-setup.service" (subsystemDevice n) ];
            bindsTo = deps;
            partOf = [ "network-setup.service" ];
            after = [ "network-pre.target" ] ++ deps;
            before = [ "network-setup.service" ];
            serviceConfig.Type = "oneshot";
            serviceConfig.RemainAfterExit = true;
            path = [ pkgs.iproute ];
            script = ''
              # Remove Dead Interfaces
              ip link show "${n}" >/dev/null 2>&1 && ip link delete "${n}"
              ip link add link "${v.interface}" name "${n}" type vlan id "${toString v.id}"
              
              # We try to bring up the logical VLAN interface. If the master 
              # interface the logical interface is dependent upon is not up yet we will 
              # fail to immediately bring up the logical interface. The resulting logical
              # interface will brought up later when the master interface is up.
              ip link set "${n}" up || true
            '';
            postStop = ''
              ip link delete "${n}" || true
            '';
          });

      in listToAttrs (
           map configureAddrs interfaces ++
           map createTunDevice (filter (i: i.virtual) interfaces))
         // mapAttrs' createBridgeDevice cfg.bridges
         // mapAttrs' createVswitchDevice cfg.vswitches
         // mapAttrs' createBondDevice cfg.bonds
         // mapAttrs' createMacvlanDevice cfg.macvlans
         // mapAttrs' createSitDevice cfg.sits
         // mapAttrs' createVlanDevice cfg.vlans
         // {
           "network-setup" = networkSetup;
           "network-local-commands" = networkLocalCommands;
         };

    services.udev.extraRules =
      ''
        KERNEL=="tun", TAG+="systemd"
      '';


  };

in

{
  config = mkMerge [
    bondWarnings
    (mkIf (!cfg.useNetworkd) normalConfig)
    { # Ensure slave interfaces are brought up
      networking.interfaces = genAttrs slaves (i: {});
    }
  ];
}
