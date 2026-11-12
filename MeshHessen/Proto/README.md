# Meshtastic protobuf sources

The `.proto` files in `meshtastic/` come from the upstream repository
<https://github.com/meshtastic/protobufs> at commit
`ffd5ad428da6db4a7ddfe62e06548718cc2603e0` (v2.8.2, the same pin the Windows client uses).

Only the files the Swift code needs are copied, plus whatever they import
(currently `field_metadata.proto`, which `atak`, `config`, `mesh` and `module_config` import).

## Local patch

Upstream sets `option swift_prefix = "";` in every file. That would generate unprefixed type
names (`NodeInfo`, `PortNum`, ...) that collide with the app's own models. The line
`option swift_prefix = "";` is therefore **deleted from every copied file**. Nothing else is
changed. Without the option, protoc-gen-swift derives the prefix from the package name, so the
generated types keep the `Meshtastic_` prefix (`Meshtastic_NodeInfo`, `Meshtastic_PortNum`, ...).

Repeat this patch on every update:

```bash
for f in MeshHessen/Proto/meshtastic/*.proto; do
    sed -i '' '/^option swift_prefix = "";$/d' "$f"
done
```

## Regenerating

From the repository root:

```bash
rm -f MeshHessen/Generated/*.pb.swift
protoc --proto_path=MeshHessen/Proto --swift_out=MeshHessen/Generated MeshHessen/Proto/meshtastic/*.proto
mv MeshHessen/Generated/meshtastic/*.pb.swift MeshHessen/Generated/ && rmdir MeshHessen/Generated/meshtastic
```

protoc writes into a `meshtastic/` subfolder; the move restores the flat layout in
`MeshHessen/Generated/`, which holds exactly one `.pb.swift` per `.proto`. Never edit the
generated files by hand.
