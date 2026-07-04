# CDI specs for `gpu("shared")`

A [Container Device Interface](https://github.com/cncf-tags/container-device-interface)
(CDI) spec is a plain YAML/JSON file in `/etc/cdi/` (or `/var/run/cdi/`) that names
a device and the edits a runtime applies to expose it. When aeo brings up a
`container(){ gpu("shared") }` node it **probes for a CDI GPU spec first**: if one is
present it renders the structured selector `--device <vendor>.com/gpu=all` (the full
device bundle); otherwise it falls back to the raw DRI render node
`--device /dev/dri/renderD128`. Both are proven live on an Intel N100.

## Why CDI beats the raw `--device`

`--device /dev/dri/renderD128` maps **only** the render node — fine for OpenCL /
transcode. But the Intel UMD uses the `/dev/dri/by-path/` symlinks to detect hardware
properties, and VA-API/QSV media apps also want the primary `card` node. The CDI
`all` device delivers **card + render + by-path** in one portable selector, the same
shape across vendors (`intel.com/gpu`, `nvidia.com/gpu`, `amd.com/gpu`).

## Not `--gpus`

`podman run --gpus all` **fails on Intel** — it hard-codes nvidia/AMD CDI auto-detect
(`Error: ... no known GPU vendor found in CDI specs`). aeo never uses `--gpus`; the
two `--device` forms above are the portable paths.

## `intel-gpu.yaml`

A hand-written spec for the Intel Alder Lake-N (N100) iGPU — topology probed live
(PCI `0000:00:02.0`, `card1` 226:1 + `renderD128` 226:128). It matches what Intel's
`cdi-specs-generator` (from `intel-resource-drivers-for-kubernetes`) emits per host;
hand-writing it needs no Go toolchain. Device numbers vary per host — regenerate or
edit the paths for a different machine.

Install and use:

```sh
sudo mkdir -p /etc/cdi
sudo cp intel-gpu.yaml /etc/cdi/
# now: podman run --rm --device intel.com/gpu=all alpine ls /dev/dri
# and any aeo container(){ gpu("shared") } auto-prefers intel.com/gpu=all
```
