import LocalAuthentication
import SwiftUI

struct LockView: View {
    @Environment(BiometricLockService.self) private var lockService

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "lock.fill")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(.primary.opacity(0.8))
                .padding(.bottom, 28)

            Text("AssetRack is Locked")
                .font(.title2.weight(.semibold))
                .padding(.bottom, 8)

            Text("Authenticate to view your accounts")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            if let error = lockService.authError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 20)
            }

            Button {
                Task { await lockService.authenticate() }
            } label: {
                Label(unlockLabel, systemImage: biometryIcon)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)
            .padding(.bottom, 60)
        }
        // Fill the whole window with an opaque background so nothing underneath
        // shows through while locked.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private var biometryIcon: String {
        switch lockService.biometryType {
        case .faceID:   return "faceid"
        case .touchID:  return "touchid"
        default:        return "lock.open.fill"
        }
    }

    private var unlockLabel: String {
        switch lockService.biometryType {
        case .faceID:   return "Unlock with Face ID"
        case .touchID:  return "Unlock with Touch ID"
        default:        return "Unlock with Passcode"
        }
    }
}

#Preview {
    let service = BiometricLockService()
    LockView()
        .environment(service)
}
