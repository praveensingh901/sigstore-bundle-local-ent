# Pinned TUF root

`1.root.json` is committed here after the TUF ceremony (10-deployment-runbook.md §5). It is the one file
every client pins: Kyverno (`tuf.root.data` = its base64), runner images and laptops
(`cosign initialize --root`), and rekor-monitor. Later root versions are fetched by clients through TUF
and do not need to be committed here.
