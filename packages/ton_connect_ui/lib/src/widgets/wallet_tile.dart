import 'package:flutter/material.dart';
import 'package:ton_connect/ton_connect.dart';

/// One wallet row in the picker.
class WalletTile extends StatelessWidget {
  /// Creates a tile for [wallet].
  const WalletTile({
    required this.wallet,
    required this.onTap,
    super.key,
    this.subtitle,
    this.trailing,
  });

  /// The wallet this row offers.
  final WalletApp wallet;

  /// Called when the user picks this wallet.
  final VoidCallback onTap;

  /// Optional line under the wallet name.
  final String? subtitle;

  /// Optional trailing widget, such as an "installed" marker.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: _WalletIcon(url: wallet.imageUrl, name: wallet.name),
      title: Text(wallet.name),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: trailing,
    );
  }
}

/// The wallet's registry icon, with a readable fallback.
///
/// Icons are remote PNGs, so they can be slow or missing. A picker that shows
/// blank squares while they load is worse than one that shows initials, because
/// the user cannot tell the wallets apart at the moment they are choosing.
class _WalletIcon extends StatelessWidget {
  const _WalletIcon({required this.url, required this.name});

  final String url;
  final String name;

  @override
  Widget build(BuildContext context) {
    final fallback = _Initial(name: name);
    return SizedBox(
      width: 40,
      height: 40,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.network(
          url,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => fallback,
          frameBuilder: (_, child, frame, wasSynchronous) {
            if (wasSynchronous || frame != null) return child;
            return fallback;
          },
        ),
      ),
    );
  }
}

class _Initial extends StatelessWidget {
  const _Initial({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Text(
          name.isEmpty ? '?' : name.characters.first.toUpperCase(),
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}
