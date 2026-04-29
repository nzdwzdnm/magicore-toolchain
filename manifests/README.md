# magicore-toolchain manifests

Each `vX.Y.Z/manifest.yaml` is the authoritative version pin and sha256
list for one toolchain release.

Manifests must always have explicit sha256 values before the
corresponding Release is cut. The placeholder string `"TODO"` causes
`scripts/fetch-and-pack.sh` to abort with a typed error rather than
producing an unverifiable artifact.

To bring up a new manifest:

```
cp -r manifests/v1.0.0 manifests/v1.1.0
$EDITOR manifests/v1.1.0/manifest.yaml          # bump versions
scripts/refresh-shas.sh v1.1.0                  # downloads + records sha256s
```

(`refresh-shas.sh` is a future helper; for v1.0.0 the sha256s are
copy-pasted from each upstream's published `SHASUMS256.txt`.)
