import KeybinddCore
import SwiftUI

struct SpacesAnimationView: View {
  let mode: AppOpenMode
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase

  private let cardW: CGFloat = 46
  private let cardH: CGFloat = 56
  private let gap: CGFloat = 16
  private let winW: CGFloat = 28
  private let winH: CGFloat = 18
  private let cycle: TimeInterval = 3.0

  private var panelW: CGFloat {
    cardW * 3 + gap * 2
  }

  private func cardX(_ index: Int) -> CGFloat {
    cardW / 2 + CGFloat(index) * (cardW + gap)
  }

  private var winY: CGFloat {
    cardH / 2 + 3
  }

  var body: some View {
    Group {
      if reduceMotion || scenePhase != .active {
        stage(t: 1, reduced: true)
      } else {
        TimelineView(.animation) { context in
          stage(
            t: context.date.timeIntervalSinceReferenceDate
              .truncatingRemainder(dividingBy: cycle) / cycle,
            reduced: false
          )
        }
      }
    }
    .frame(width: panelW, height: cardH + 18)
    .id(mode)
    .transition(.opacity)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: mode)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private func stage(t: Double, reduced: Bool) -> some View {
    ZStack(alignment: .topLeading) {
      ForEach(0..<3, id: \.self) { index in
        SpaceCard(isCurrent: index == 2)
          .frame(width: cardW, height: cardH)
          .position(x: cardX(index), y: cardH / 2)
      }

      Text("Current")
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(.tint)
        .position(x: cardX(2), y: cardH + 8)

      if mode == .newWindow {
        WindowChip(focused: false)
          .frame(width: winW, height: winH)
          .opacity(0.45)
          .position(x: cardX(0), y: winY)
      }

      if reduced && mode == .move {
        Image(systemName: "arrow.right")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(.tint)
          .position(x: (cardX(0) + cardX(2)) / 2, y: winY)
      }

      animatedWindow(t: t, reduced: reduced)
    }
  }

  @ViewBuilder
  private func animatedWindow(t: Double, reduced: Bool) -> some View {
    switch mode {
    case .launch:
      let amount = smoothstep(0.12, 0.42, t)
      let opacity = reduced ? 1 : amount * (1 - smoothstep(0.90, 1.0, t))
      WindowChip(focused: reduced || glow(t, 0.42))
        .frame(width: winW, height: winH)
        .scaleEffect(reduced ? 1 : 0.7 + 0.3 * amount)
        .opacity(opacity)
        .position(x: cardX(2), y: winY)

    case .newWindow:
      let amount = smoothstep(0.15, 0.45, t)
      let opacity = reduced ? 1 : amount * (1 - smoothstep(0.90, 1.0, t))
      WindowChip(focused: reduced || glow(t, 0.45), badge: true)
        .frame(width: winW, height: winH)
        .scaleEffect(reduced ? 1 : 0.7 + 0.3 * amount)
        .opacity(opacity)
        .position(x: cardX(2), y: winY)

    case .move:
      let progress = smoothstep(0.18, 0.70, t)
      let x = reduced ? cardX(2) : cardX(0) + (cardX(2) - cardX(0)) * progress
      let arc = reduced ? 0 : sin(progress * .pi) * 6
      let opacity = reduced ? 1 : smoothstep(0.0, 0.08, t) * (1 - smoothstep(0.92, 1.0, t))
      WindowChip(focused: reduced || glow(t, 0.70))
        .frame(width: winW, height: winH)
        .opacity(opacity)
        .position(x: x, y: winY - arc)
    }
  }

  private func glow(_ t: Double, _ start: Double) -> Bool {
    t >= start && t < start + 0.22
  }
}

private struct SpaceCard: View {
  var isCurrent: Bool

  var body: some View {
    RoundedRectangle(cornerRadius: 6, style: .continuous)
      .fill(.thinMaterial)
      .overlay {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(isCurrent ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1.2)
      }
  }
}

private struct WindowChip: View {
  var focused: Bool
  var badge = false

  var body: some View {
    RoundedRectangle(cornerRadius: 4, style: .continuous)
      .fill(Color.accentColor.opacity(focused ? 0.78 : 0.48))
      .overlay(alignment: .top) {
        Rectangle()
          .fill(.white.opacity(0.35))
          .frame(height: 3)
          .clipShape(
            UnevenRoundedRectangle(
              topLeadingRadius: 4,
              bottomLeadingRadius: 0,
              bottomTrailingRadius: 0,
              topTrailingRadius: 4
            )
          )
      }
      .overlay {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .stroke(Color.accentColor.opacity(focused ? 0.9 : 0.35), lineWidth: focused ? 2 : 1)
      }
      .overlay(alignment: .topTrailing) {
        if badge {
          Image(systemName: "plus")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 12, height: 12)
            .background(Color.accentColor, in: Circle())
            .offset(x: 5, y: -5)
        }
      }
      .shadow(color: .black.opacity(focused ? 0.18 : 0.08), radius: focused ? 2 : 1, y: 1)
  }
}

private func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
  let t = min(max((x - a) / (b - a), 0), 1)
  return t * t * (3 - 2 * t)
}
