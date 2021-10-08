# megapixels_postprocess

This is a custom postprocess.sh script to be used for [megapixels](https://git.sr.ht/~martijnbraam/megapixels). This was developed and tested for the pinephone but theres nothing specific to the pinephone so it should work on whatever megapixels supports.

## Usage

Clone the repo and copy the postprocess.sh to /etc/megapixels/postprocess.sh

The biggest benefit to this is image stacking to reduce the amount of noise in the image by combining the burst images taken by megapixels. To use this feature you need to clone the repo <https://github.com/luigi311/Low-Power-Image-Processing> in the same directory /etc/megapixels/
The script requires opencv to be installed globally such as with

```bash
sudo pip install opencv-python-headless
```

A full run with stacking and all comes in at around 1 minute on the pinephone and should be around 30 seconds without the stacking.
