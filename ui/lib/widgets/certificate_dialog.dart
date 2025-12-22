import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/system_proxy_service.dart';
import '../core/models/traffic_state.dart';

/// Dialog shown on first launch to guide user through certificate installation
class CertificateOnboardingDialog extends StatefulWidget {
  final String certPath;
  final VoidCallback onComplete;
  final VoidCallback? onSkip;
  final bool isTrusted;

  const CertificateOnboardingDialog({
    super.key,
    required this.certPath,
    required this.onComplete,
    this.onSkip,
    this.isTrusted = false,
  });

  @override
  State<CertificateOnboardingDialog> createState() =>
      _CertificateOnboardingDialogState();
}

class _CertificateOnboardingDialogState
    extends State<CertificateOnboardingDialog> {
  CertificateInfo? _certInfo;
  String _status = 'loading'; // loading, ready, importing, success, error
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    if (widget.isTrusted) {
      _status = 'success';
    }
    _loadCertificateInfo();
  }

  Future<void> _loadCertificateInfo() async {
    // Don't reset to loading if we are already showing success
    if (_status != 'success') {
      setState(() => _status = 'loading');
    }

    final info = await SystemProxyService.getCertificateInfo(widget.certPath);

    if (info != null) {
      setState(() {
        _certInfo = info;
        if (_status != 'success') {
          _status = 'ready';
        }
      });
    } else {
      setState(() {
        _status = 'error';
        _errorMessage = 'Could not load certificate. Please restart the app.';
      });
    }
  }

  Future<void> _trustAndImport() async {
    setState(() => _status = 'importing');

    final installed =
        await SystemProxyService.installCertificateToLoginKeychain(
          widget.certPath,
        );
    if (!installed) {
      setState(() {
        _status = 'ready';
        _errorMessage = 'Failed to add certificate to keychain.';
      });
      return;
    }

    final success = await SystemProxyService.trustAndImportCertificate(
      widget.certPath,
    );

    if (success) {
      if (mounted) {
        await context.read<TrafficState>().refreshCertificateStatusNow();
      }
      setState(() => _status = 'success');
      // Wait briefly to show success state
      await Future.delayed(const Duration(milliseconds: 800));
      widget.onComplete();
    } else {
      setState(() {
        _status = 'ready';
        _errorMessage =
            'Failed to import certificate. You may need to install it manually.';
      });
    }
  }

  Future<void> _saveCertificate() async {
    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Cheddar Proxy CA certificate',
      fileName: 'cheddar_proxy_ca.pem',
      type: FileType.custom,
      allowedExtensions: ['pem', 'crt', 'cer'],
    );

    if (result != null) {
      final success = await SystemProxyService.saveCertificateTo(
        widget.certPath,
        result,
      );
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Certificate saved to: $result'),
            backgroundColor: AppColors.success,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        width: 520,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            _buildHeader(),
            const SizedBox(height: 20),

            // Certificate preview panel
            _buildCertificatePreview(),

            // Error message if any
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              _buildErrorMessage(),
            ],

            const SizedBox(height: 24),

            // Action buttons
            _buildActionButtons(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            _status == 'success' ? Icons.check_circle : Icons.security,
            color: _status == 'success' ? AppColors.success : AppColors.primary,
            size: 24,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _status == 'success'
                    ? 'Certificate Installed!'
                    : 'Certificate Setup Required',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _status == 'success'
                    ? 'Cheddar Proxy is now ready to inspect HTTPS traffic.'
                    : 'To inspect HTTPS traffic, Cheddar Proxy needs you to trust its certificate.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCertificatePreview() {
    if (_status == 'loading') {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.surfaceBorder),
        ),
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    if (_certInfo == null) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row with certificate icon and save button
          Row(
            children: [
              Icon(
                Icons.description_outlined,
                color: AppColors.textSecondary,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'Cheddar Proxy CA certificate',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              // Save/Download button
              Tooltip(
                message: 'Save certificate to disk',
                child: IconButton(
                  icon: Icon(
                    Icons.download_outlined,
                    color: AppColors.textSecondary,
                    size: 18,
                  ),
                  onPressed: _saveCertificate,
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  splashRadius: 16,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Certificate details
          _buildDetailRow('Issuer', _certInfo!.issuer),
          _buildDetailRow('Valid From', _certInfo!.notBefore),
          _buildDetailRow('Valid Until', _certInfo!.notAfter),
          _buildDetailRow('Fingerprint (SHA-256)', _certInfo!.shortFingerprint),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorMessage() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.clientError.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.clientError.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber, color: AppColors.clientError, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _errorMessage!,
              style: TextStyle(color: AppColors.clientError, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    if (_status == 'success') {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          ElevatedButton(
            onPressed: widget.onComplete,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.success,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            child: const Text('Continue'),
          ),
        ],
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        // Skip button
        if (widget.onSkip != null)
          TextButton(
            onPressed: widget.onSkip,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textMuted,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            child: const Text('Skip for Now'),
          ),
        const SizedBox(width: 12),

        // Trust & Import button
        ElevatedButton(
          onPressed: _status == 'importing' || _status == 'loading'
              ? null
              : _trustAndImport,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          ),
          child: _status == 'importing'
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.security, size: 16),
                    SizedBox(width: 8),
                    Text('Trust & Import'),
                  ],
                ),
        ),
      ],
    );
  }
}
