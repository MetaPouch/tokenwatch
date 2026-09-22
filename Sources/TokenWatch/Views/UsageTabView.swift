import SwiftUI
import TokenWatchCore

/// Consolidated quota-meter view across every locally discovered account for every enabled
/// provider: the default account each provider's own dashboard card already tracks, plus any
/// additional local logins TokenWatch can discover (currently: Claude, Codex, via a second
/// `CLAUDE_CONFIG_DIR`/`CODEX_HOME` profile -- see `ClaudeAccountDiscovery`/
/// `CodexAccountDiscovery`). Each account's lines render through `ProviderCardView`, the same
/// generic renderer the per-provider tab uses -- no separate formatting/coloring logic here, and
/// no provider gets bespoke SwiftUI in either tab.
struct UsageTabView: View {
    @ObservedObject var usageService: MultiAccountUsageService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if usageService.accounts.isEmpty {
                    Text(usageService.isRefreshing ? "Loading…" : "No accounts found")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else {
                    ForEach(usageService.accounts) { account in
                        accountCard(account)
                    }
                }
                UsageHistoryView()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .task {
            // Show whatever's already cached immediately (no network wait), then look for
            // additional local accounts -- the only part of this tab that makes a fresh call.
            usageService.refreshDefaultAccountsFromCache()
            await usageService.refreshAdditionalAccounts()
        }
    }

    private func accountCard(_ account: ProviderAccount) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderIcon(provider: account.providerID, size: 14)
                Text(account.providerID.displayName)
                    .font(.caption.weight(.semibold))
                if !account.label.isEmpty {
                    Text(account.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if account.isDefault {
                    Text("Default")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            ProviderCardView(snapshot: ProviderSnapshot(
                provider: account.providerID,
                plan: nil,
                lines: account.lines,
                fetchedAt: account.fetchedAt,
                error: account.error
            ))
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}
