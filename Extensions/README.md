# Extension setup checklist

These files are scaffolded for MVP and must be attached to dedicated extension targets in Xcode:

1. Create target `DeviceActivityMonitorExtension` (Device Activity Monitor Extension).
2. Create target `ShieldConfigurationExtension` (Shield Configuration Extension).
3. Create target `ShieldActionExtension` (Shield Action Extension).
4. Add Family Controls capability to app + all extensions.
5. Add the same App Group to app + all extensions: `group.mycompny.parentalcontrol`.
6. Ensure extension bundles have the Family Controls entitlement.
7. Use provided `Info.plist` and `*.entitlements` files from each extension folder.

After target wiring, move the corresponding source files into each extension target membership.
