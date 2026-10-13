# /// script
# requires-python = ">=3.10,<3.13"
# dependencies = [
#   "torch==2.5.0",
#   "torchvision==0.20.0",
#   "coremltools==8.3.0",
#   "numpy==1.26.4",
#   "safetensors==0.4.5",
#   "huggingface_hub==0.26.2",
#   "pillow==11.0.0",
# ]
# ///
"""Converts the pretrained ETH-XGaze ResNet-18 gaze network to Core ML (Models/GazeNet.mlpackage).

Weights: hysts/ptgaze-eth-xgaze-resnet18 on Hugging Face, trained on the ETH-XGaze dataset
(CC BY-NC-SA 4.0: non-commercial use only).

The Core ML model takes the 224x224 normalized face patch as an RGB image and returns
`gaze` = [pitch, yaw] in radians in the normalized camera (see FaceNormalization in GazeNetwork.swift),
and `features`, the 512 values the final layer reads, for learning a per-user correction.
ImageNet mean/std normalization is built in, matching ptgaze's ETH-XGaze transform.

Run: uv run scripts/convert-gaze-model.py
"""
import pathlib
import sys

import coremltools as ct
import numpy as np
import torch
import torchvision
from huggingface_hub import hf_hub_download
from safetensors.torch import load_file


class GazeNet(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.feature_extractor = torchvision.models.resnet18()
        self.feature_extractor.fc = torch.nn.Identity()
        self.fc = torch.nn.Linear(512, 2)

    def forward(self, x):
        features = self.feature_extractor(x)
        return self.fc(features), features


class WithPreprocessing(torch.nn.Module):
    """Takes RGB in 0...1 (Core ML scales the image by 1/255) and applies ImageNet normalization."""

    def __init__(self, net):
        super().__init__()
        self.net = net
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))

    def forward(self, image):
        return self.net((image - self.mean) / self.std)


def load_weights(net):
    state = load_file(hf_hub_download("hysts/ptgaze-eth-xgaze-resnet18", "model.safetensors"))
    renamed = {}
    for key, value in state.items():
        for prefix in ("module.", "model."):
            if key.startswith(prefix):
                key = key[len(prefix):]
        # A plain torchvision/timm ResNet with a 2-output head, or ptgaze's feature_extractor + fc.
        if not key.startswith(("feature_extractor.", "fc.")):
            key = "feature_extractor." + key
        renamed[key] = value
    missing, unexpected = net.load_state_dict(renamed, strict=False)
    if missing or unexpected:
        print("Checkpoint keys:", sorted(state)[:10], "...", file=sys.stderr)
        sys.exit(f"Weights don't match the architecture. Missing: {missing}, unexpected: {unexpected}")


def main():
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "Models/GazeNet.mlpackage")
    net = GazeNet()
    load_weights(net)
    model = WithPreprocessing(net).eval()

    example = torch.rand(1, 3, 224, 224)
    traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / 255, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="gaze"), ct.TensorType(name="features")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS13,
    )
    mlmodel.short_description = "ETH-XGaze ResNet-18: normalized 224x224 face → gaze [pitch, yaw] (radians)"
    mlmodel.license = "CC BY-NC-SA 4.0 (ETH-XGaze), non-commercial"

    # Check the conversion against PyTorch on a random image.
    from PIL import Image

    pixels = (np.random.rand(224, 224, 3) * 255).astype(np.uint8)
    with torch.no_grad():
        expected = model(torch.from_numpy(pixels).permute(2, 0, 1)[None].float() / 255)[0].numpy()
    actual = mlmodel.predict({"image": Image.fromarray(pixels)})["gaze"]
    print(f"PyTorch {expected.ravel()}, Core ML {np.asarray(actual).ravel()}")
    if np.abs(expected - actual).max() > 0.02:
        sys.exit("Core ML output differs from PyTorch")

    out.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(out))
    print(f"Saved {out}")


if __name__ == "__main__":
    main()
