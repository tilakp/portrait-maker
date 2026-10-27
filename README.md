# Portrait Maker

A Mac app that teaches you to draw a portrait from a photo, the way a drawing teacher would. Open a portrait, and the app makes 13 guide steps: proportions and the block-in, the planes of the head, the light and shadow families, the form (halftone, core shadow, reflected light, cast shadows), value steps, edges and details. Then take a photo of your drawing: the app aligns it to the reference and lists what to correct, with distances in millimeters on your paper.

The method follows a tutorial by [Will Davies (@willdaviesart)](https://www.instagram.com/willdaviesart/): change the photo into a few flat value shapes, then copy those shapes in order, instead of shading small parts one at a time.

<p align="center">
  <img src="docs/form.png" width="720" alt="Form step: highlight, light, halftone, core shadow, shadow, reflected light, cast shadow and dark local values, with the light direction">
</p>
<p align="center">
  <img src="docs/planes.png" width="380" alt="Planes of the head, shaded by the light in the photo">
  <img src="docs/check.png" width="380" alt="Drawing check: a list of corrections in millimeters and value steps">
</p>

## What it does

**The 3D form of the head.** A depth model (Depth Anything V2) gives the form of the head. From it, and from the photo, the app finds:

- the direction of the light, for example "The light comes from above and the left, 59° from the front"
- the **light family** and the **shadow family**, separate from **dark local values**: hair, a beard or a dark coat in the light are not shadows, and a threshold on the photo alone cannot tell the difference
- the **form**: highlight, light, halftone, core shadow, shadow, reflected light and cast shadows
- the **planes of the head**, each shaded flat by the light in the photo

**13 steps in 4 groups.** You can skip any step from the sidebar.

| Group | Steps |
|---|---|
| Shape | Proportions (skull circle, jaw, brow, nose and chin lines), Block-in with straight lines, Planes, Features on guide lines |
| Tone | Base tone, Shadow shapes (the two families), Form, Values (2 to 9 steps), Darkest accents, Highlights |
| Finish | Edges (hard and soft), Details |
| Check | Check your drawing |

**Measurements in the units that artists use.** For example: the eye line as a part of the head height, the space between the eyes and the face width in eye widths, and the nose base to the chin against the brow to the nose base. Each one has the usual canon value next to it. Click a measurement to see it on the picture. The **Measure** tool gives the length between two points in eye widths and as a part of the head height, and the angle from vertical.

**Values.** You choose 2 to 9 value steps, and step 1 is the lightest. Each step shows the median tone of the photo in that step. **Compare values** shows two points on the same neutral gray, with their steps, so that the values around them cannot trick your eye.

**Check your drawing.**
- The app finds the paper in the photo, removes the perspective and makes the paper white. With the paper size (A4, A3, Letter, 9 × 12 in or 11 × 14 in), it knows the millimeters for each pixel.
- It aligns the drawing by the eyes, found automatically or by two clicks, then by the tones of the full head.
- **Shapes.** Each feature and each side of the head is searched again, and the error is measured against the drawing as a whole. A drawing that is a little larger or turned is not an error. For example: "Eye on the right: Move it 2.2 mm up." or "Mouth: It is 15% too wide: check its corners against the pupils."
- **Values.** Connected patches that are wrong, named by the area and the family. For example: "Cheek on the right, shadow side: About 1 value step too light in an area about 12 mm wide."
- Pencil cannot be as dark as a photo, so the drawing is compared in its own range of values.

**Tools:** grid (3 to 8 columns of square cells), squint (blur), flip (mirror), and the photo under the lines.

All image processing happens on your Mac. The app makes no network calls. The depth model is in the app bundle.

## Accuracy

I tested the drawing check with test drawings made from two reference photos (Lincoln, 1863, and Marie Curie, about 1920). The test drawings have pencil texture and are on A4 paper with uneven light, photographed in perspective on a dark table.

| Test drawing | What the app reports |
|---|---|
| Exact copy (both photos) | No corrections. Values match on 99% and 100% of the head. |
| Eye moved 2.7 mm down | "Move it 2.2 mm up" (Lincoln), "Move it 1.8 mm up" (Curie) |
| Mouth 18% wider | "15% too wide" (Lincoln), "19% too wide" (Curie) |
| Cheek much lighter | "About 1 value step too light" (both) |
| Scale of the paper | 0.1686 to 0.1693 mm per pixel, true value 0.1694 |

The test drawings are copies of the photo with changes made on purpose, so these results show the accuracy of the measurement, not of every drawing style. The check has not been tested on many real pencil drawings yet. Unit tests (`swift test`) cover the light fit, the local shape search, the alignment of the drawing as a whole, the tone matching and the wording of the corrections.

## Requirements

- macOS 14 or later. Tested on Apple silicon.
- To build: Xcode 15.3 or later (the SwiftUI macros need the Xcode toolchain, not only the Command Line Tools), and a network connection the first time, to download the depth model (50 MB).

## Install

Download `PortraitMaker.zip` from [Releases](../../releases), unzip it, and move `PortraitMaker.app` to Applications. The app is not signed or notarized, so the first time, right-click the app and choose **Open**.

Or build from source:

```sh
git clone https://github.com/tilakp/portrait-maker.git
cd portrait-maker
./build_app.sh            # downloads the depth model once, builds PortraitMaker.app
./build_app.sh --install  # also copies it to /Applications
swift test                # unit tests
```

The first time the app starts after an install, Core ML prepares the depth model on the GPU in the background, which takes about 10 seconds. After that, a portrait takes about 1 second.

## Usage

1. Open a portrait: click **Open**, or drop a photo on the window. A clear photo with strong light from one side gives the best results.
2. Go through the steps with **Next** (Return) and **Back**, or click a step in the sidebar.
3. On **Check your drawing**, add a photo of all of your paper from straight above, in even light, on a darker table, and choose the paper size. If the app does not find the face in your drawing, click the center of the eye on the left, then the eye on the right.

From the terminal:

```sh
# Open a portrait and a drawing at launch
open -a PortraitMaker.app --args <portrait> [<photo of drawing>]

# Write every step as a PNG file, and print the measurements and the corrections
PortraitMaker.app/Contents/MacOS/PortraitMaker --render <portrait> <output folder> [<photo of drawing> [A4|A3|Letter|...]]

# Write the depth, normals, fitted light and form classes as PNG files
PortraitMaker.app/Contents/MacOS/PortraitMaker --form <portrait> <output folder>
```

Set `PM_DEBUG=1` to print the timing of each step and the result of each local search.

## How it works

- **Face and person**: Apple's Vision framework finds the face, the face landmarks and a mask of the person, and the app crops the photo to the head.
- **Form**: Depth Anything V2 Small (Core ML, on the GPU) gives relative depth. The depth is scaled so that the nose tip is in front of the cheek outline by half the face width, and the surface normals come from it.
- **Light**: a Lambertian fit on the skin, brightness = ambient + albedo × (normal · light). Pixels that are much darker than the fit (a beard, a cast shadow) are removed, and the fit runs again.
- **Families and form**: on smooth skin, a dark tone means shadow. On hair, a beard, the brows and clothes, the 3D form decides if a dark area is a shadow or a dark local value. Hair and beards are found by their fine texture. The terminator is moved to where the form agrees best with the photo.
- **Planes**: k-means clustering of the smoothed normals into 12 directions, started from fixed directions so that the result is the same each time.
- **Lines**: the head outline comes from the person mask. The Douglas-Peucker algorithm keeps only its corners, so curves become straight lines.
- **Drawing check**: Vision finds the paper, and Core Image removes the perspective. The light on the paper is fitted to a band along the edges of the paper. The alignment uses the eyes, then a coarse-to-fine search over size, rotation and position (Pearson correlation). For each area, the app matches the tone distribution of the drawing to the photo and searches the position and the size again. One similarity transform is fitted to all the local results without the outliers, and only what is left is reported. Widths come from the corners of the mouth and the wings of the nose.

## Project layout

```
Sources/PortraitMaker/
  Stage.swift            the steps, their order and their instructions
  LessonBuilder.swift    Vision, value maps, edges, lines, and the lesson model
  FormAnalysis.swift     depth model, normals and the light fit
  FormClasses.swift      light and shadow families, form classes and planes
  Measurements.swift     proportions in eye widths and head units
  DrawingCheck.swift     paper detection, perspective, white balance and alignment
  DrawingFeedback.swift  shape and value corrections
  LinearAlgebra.swift    least squares
  ContentView.swift      the SwiftUI app
  Entry.swift            app entry and the --render and --form debug modes
Tests/PortraitMakerTests/ unit tests
scripts/fetch_model.sh   downloads and checks the depth model at a fixed commit
scripts/make_icon.swift  draws the app icon
build_app.sh             builds and signs the .app bundle
```

## Attribution

- The drawing method is from a tutorial reel by Will Davies ([@willdaviesart](https://www.instagram.com/willdaviesart/)).
- Depth model: [Depth Anything V2](https://github.com/DepthAnything/Depth-Anything-V2) by Lihe Yang et al., Small model, Apache License 2.0, in [Apple's Core ML conversion](https://huggingface.co/apple/coreml-depth-anything-v2-small). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- The screenshots use the 1863 portrait of Abraham Lincoln by Alexander Gardner, which is in the public domain ([Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Abraham_Lincoln_O-77_matte_collodion_print.jpg)). The drawing in the check screenshot is a test image made from the photo, with errors added on purpose.

## License

[MIT](LICENSE)
