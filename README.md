# app-images

Container images that GalaxyGate builds for its one-click app catalog. Each folder is one image. GitHub Actions builds it and publishes it as a public package at `ghcr.io/galaxygate/<folder>:<TAG>`.

| Folder | Image |
| --- | --- |
| `hermes-agent` | Hermes Agent with the gateway set as the default command |
| `rustypaste` | Rustypaste with a baked config file |

## Add or update an image

1. Create a folder named after the image. Put a `Dockerfile` in it and pin the base image to an exact version.
2. Add a `TAG` file with one line in the form `<upstream-version>-r<rev>`, for example `1.4.2-r1`.
3. To change an existing image, edit its files and raise the `-r<rev>` number, or reset it to `r1` when the upstream version changes. A published tag is never rebuilt with different contents.
4. Push to `main`. The build workflow builds every folder the push touched for `linux/amd64` and pushes it to GHCR.

To rebuild one folder by hand, run the build workflow from the Actions tab and enter the folder name.

Packages built here are public and linked to this repo, because they inherit the repo's visibility. Anyone can pull them without logging in.
