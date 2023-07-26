# harmonized-wf-dev
Repo for testing and developing a common postmortem-derived brain sequencing (PMDBS) workflow harmonized across ASAP

## Docker images

Docker images are defined in [the `docker` directory](docker). Each image must minimally define a `build.env` file and a `Dockerfile`.

Example directory structure:
```bash
docker
├── multiome
│   ├── build.env
│   └── Dockerfile
└── samtools
    ├── build.env
    └── Dockerfile
```

### The `build.env` file

Each target image is defined using the `build.env` file, which is used to specify the name and version tag for the corresponding Docker image. It must contain at minimum the following variables:

- `IMAGE_NAME`
- `IMAGE_TAG`

All variables defined in the `build.env` file will be made available as build arguments during Docker image build.

The `DOCKERFILE` variable may be used to specify the path to a Dockerfile if that file is not found alongside the `build.env` file, for example when multiple images use the same base Dockerfile definition.

### Building Docker images

Docker images can be build using the [`build_docker_images`](util/build_docker_images) utility script.

```bash
# Build a single image
./util/build_docker_images -d docker/multiome

# Build all images in the `docker` directory
./util/build_docker_images -d docker

# Build and push all images in the docker directory, using the `dnastack` container registry
./util-build_docker_images -d docker -c dnastack -p
```
