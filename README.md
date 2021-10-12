# megapixels_postprocess

This is a custom postprocess.sh script to be used for [megapixels](https://git.sr.ht/~martijnbraam/megapixels). This was developed and tested for the pinephone but theres nothing specific to the pinephone so it should work on whatever megapixels supports.

## Usage

Clone the repo and run the following commands:

```bash
chmod +x setup.sh
chmox +x setup2.sh
./setup.sh
```

You must run the scripts as the user that will use megapixels as that user will be added to the rootless podman setup.
It will then restart the machine to finish configuring podman. You will then need to run

```bash
./setup2.sh
```

Which will download the docker image to use so it does not have to download it when it first runs the script.
