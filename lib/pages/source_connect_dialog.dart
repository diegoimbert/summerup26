import 'package:flutter/material.dart';

import '../sources/connections.dart';
import '../sources/credential_store.dart';
import '../sources/oauth.dart';
import '../sources/source_catalog.dart';
import '../theme.dart';
import '../widgets/source_logo.dart';

/// Opens the connect/disconnect sheet for a source.
Future<void> showSourceConnectDialog(
  BuildContext context, {
  required SourceDescriptor source,
  required ConnectionsController connections,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) =>
        _SourceConnectDialog(source: source, connections: connections),
  );
}

class _SourceConnectDialog extends StatefulWidget {
  const _SourceConnectDialog({required this.source, required this.connections});

  final SourceDescriptor source;
  final ConnectionsController connections;

  @override
  State<_SourceConnectDialog> createState() => _SourceConnectDialogState();
}

class _SourceConnectDialogState extends State<_SourceConnectDialog> {
  final TextEditingController _clientId = TextEditingController();
  final TextEditingController _clientSecret = TextEditingController();

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadClient();
  }

  @override
  void dispose() {
    _clientId.dispose();
    _clientSecret.dispose();
    super.dispose();
  }

  Future<void> _loadClient() async {
    final client = await widget.connections.clientFor(widget.source.id);
    if (!mounted) return;
    setState(() {
      _clientId.text = client?.clientId ?? '';
      _clientSecret.text = client?.clientSecret ?? '';
      _loading = false;
    });
  }

  Future<void> _connect() async {
    await widget.connections.saveClient(
      widget.source.id,
      OAuthClient(
        clientId: _clientId.text.trim(),
        clientSecret: _clientSecret.text.trim().isEmpty
            ? null
            : _clientSecret.text.trim(),
      ),
    );
    await widget.connections.connect(widget.source.id);
  }

  Future<void> _disconnect() async {
    await widget.connections.disconnect(widget.source.id);
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final provider = kOAuthProviders[source.id];

    return AnimatedBuilder(
      animation: widget.connections,
      builder: (context, _) {
        final credentials = widget.connections.connectionFor(source.id);
        final busy = widget.connections.isBusy(source.id);
        final error = widget.connections.errorFor(source.id);

        return Dialog(
          backgroundColor: KandooColors.background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SourceLogo(source: source, size: 38),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              source.name,
                              style: const TextStyle(
                                fontFamily: KandooFonts.heading,
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                                color: KandooColors.textPrimary,
                              ),
                            ),
                            Text(
                              credentials == null
                                  ? source.tagline
                                  : 'Connected'
                                        '${credentials.accountLabel == null ? '' : ' · ${credentials.accountLabel}'}',
                              style: const TextStyle(
                                fontSize: 12.5,
                                color: KandooColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  else if (credentials != null)
                    _ConnectedBody(credentials: credentials)
                  else ...[
                    if (provider != null) _RedirectHint(provider: provider),
                    const SizedBox(height: 14),
                    _Field(
                      label: 'Client ID',
                      controller: _clientId,
                      hint: 'From the provider\'s developer console',
                    ),
                    const SizedBox(height: 12),
                    _Field(
                      label: source.id == 'notion'
                          ? 'Client secret'
                          : 'Client secret (optional)',
                      controller: _clientSecret,
                      hint: source.id == 'notion'
                          ? 'Notion requires this to exchange the code'
                          : 'Google desktop clients may leave this empty',
                      obscure: true,
                    ),
                  ],

                  if (error != null) ...[
                    const SizedBox(height: 14),
                    _ErrorBanner(message: error),
                  ],

                  const SizedBox(height: 22),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Close'),
                      ),
                      const SizedBox(width: 8),
                      if (credentials != null)
                        TextButton(
                          onPressed: busy ? null : _disconnect,
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFFC0392B),
                          ),
                          child: const Text('Disconnect'),
                        )
                      else
                        FilledButton(
                          onPressed: busy ? null : _connect,
                          child: Text(busy ? 'Waiting…' : 'Sign in'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Shows what was stored, without ever printing the token itself.
class _ConnectedBody extends StatelessWidget {
  const _ConnectedBody({required this.credentials});

  final SourceCredentials credentials;

  @override
  Widget build(BuildContext context) {
    final expiry = credentials.expiresAt;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: KandooColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: KandooColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailRow(
            label: 'Access token',
            value: '•••• stored locally',
          ),
          _DetailRow(
            label: 'Refresh token',
            value: credentials.refreshToken == null
                ? 'not issued'
                : '•••• stored locally',
          ),
          _DetailRow(
            label: 'Expires',
            value: expiry == null
                ? 'no expiry'
                : '${expiry.toLocal()}'.split('.').first,
          ),
          if (credentials.scopes.isNotEmpty)
            _DetailRow(
              label: 'Scopes',
              value: '${credentials.scopes.length} granted',
            ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12.5,
                color: KandooColors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontFamily: KandooFonts.mono,
                fontSize: 11.5,
                color: KandooColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The exact redirect URI the user has to register with the provider.
class _RedirectHint extends StatelessWidget {
  const _RedirectHint({required this.provider});

  final OAuthProvider provider;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: KandooColors.sidebar,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: KandooColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Register this redirect URI',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: KandooColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            provider.redirectUri,
            style: const TextStyle(
              fontFamily: KandooFonts.mono,
              fontSize: 12,
              color: KandooColors.accentDeep,
            ),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    required this.hint,
    this.obscure = false,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            color: KandooColors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
          cursorColor: KandooColors.accent,
          style: const TextStyle(fontSize: 13, fontFamily: KandooFonts.mono),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: KandooColors.surface,
            hintText: hint,
            hintStyle: const TextStyle(
              fontSize: 12.5,
              fontFamily: KandooFonts.body,
              color: KandooColors.textMuted,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 11,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(color: KandooColors.divider),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(color: KandooColors.divider),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(
                color: KandooColors.accent,
                width: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: const Color(0xFFC0392B).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        message,
        style: const TextStyle(fontSize: 12.5, color: Color(0xFF922B21)),
      ),
    );
  }
}
