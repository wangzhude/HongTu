# Public interoperability samples

These are small, unmodified layout files from their official upstream projects.
`manifest.json` records the exact source URL, upstream commit, byte count, SHA-256,
and license provenance. The corresponding license files are included.

- `sky130_fd_sc_hd__inv_1.gds`: SkyWater SKY130 high-density inverter.
- `sky130_fd_sc_hd__nand2_1.gds`: SkyWater SKY130 high-density NAND2.
- `klayout-ringo.gds`: KLayout's hierarchical ring-oscillator LVS test layout.

Regenerate with `python/fetch_public_samples.py`. The download limit is 2 MiB per
file; this fetches neither a complete PDK nor proprietary process data. These
samples exercise file formats and geometry. Reading them successfully does not
establish support for the SKY130 rule deck, electrical models or manufacturing
signoff. KLayout's sample is distributed under the upstream repository license;
no separate file-level license was identified.
