import SwiftUI

struct PreferencesBannerView: View {
  var banner: PreferencesBanner
  var resetAction: (() -> Void)?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: iconName)
        .foregroundStyle(color)
      VStack(alignment: .leading, spacing: 3) {
        Text(banner.title)
          .font(.callout.weight(.semibold))
        Text(banner.message)
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer()
      if let resetAction {
        Button("Reset") {
          resetAction()
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .accessibilityIdentifier("banner.resetButton")
      }
    }
    .padding(12)
    .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
  }

  private var iconName: String {
    switch banner.tone {
    case .info:
      "info.circle.fill"
    case .warning:
      "exclamationmark.triangle.fill"
    case .error:
      "xmark.octagon.fill"
    }
  }

  private var color: Color {
    switch banner.tone {
    case .info:
      .blue
    case .warning:
      .orange
    case .error:
      .red
    }
  }
}
