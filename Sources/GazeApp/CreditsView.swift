import SwiftUI

/// Version, and what Gaze is built on, with the terms that come with it.
struct CreditsView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                GazeMark()
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading) {
                    Text("Gaze").font(.title.weight(.bold))
                    Text("Version \(version)").foregroundStyle(.secondary)
                }
            }
            Text("Shared for personal, non-commercial use only, because the gaze network's weights are licensed that way.")
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            credit(
                "Gaze network",
                "ResNet-18 weights trained on ETH-XGaze, converted to Core ML. ETH-XGaze: Zhang, Park, Beeler, Bradley, Tang and Hilliges, “ETH-XGaze: A Large Scale Dataset for Gaze Estimation under Extreme Head Pose and Gaze Variation”, ECCV 2020. Weights: hysts/ptgaze (pytorch_mpiigaze). Licensed CC BY-NC-SA 4.0: non-commercial use only; the converted model is shared under the same license.",
                link: ("CC BY-NC-SA 4.0", "https://creativecommons.org/licenses/by-nc-sa/4.0/")
            )
            credit(
                "Sparkle",
                "Software updates. Copyright the Sparkle Project contributors. MIT license.",
                link: ("sparkle-project.org", "https://sparkle-project.org")
            )
            Text("Video from the camera is processed on this Mac and is not sent anywhere.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 460)
    }

    private func credit(_ title: String, _ text: String, link: (String, String)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Link(link.0, destination: URL(string: link.1)!).font(.callout)
        }
    }
}
