# megapixels_postprocess

This is a custom postprocess.sh script to be used for [megapixels](https://gitlab.com/postmarketOS/megapixels). This was developed and tested for the pinephone but theres nothing specific to the pinephone so it should work on whatever megapixels supports. Most of the logic is handled by python scripts from the following repo https://github.com/luigi311/Low-Power-Image-Processing that will run in a container or natively if you have it installed and accessable from the postprocess.sh script via the variables defined.

## Usage

Clone the repo and run the following commands:

```bash
chmod +x *.sh
./setup.sh
```

You must run the scripts as the user that will use megapixels as that user will be added to the rootless podman setup.
It will then restart the machine to finish configuring podman. You will then need to run

```bash
./download_container.sh
```

Which will download the docker image to use so it does not have to download it when it first runs the script.
