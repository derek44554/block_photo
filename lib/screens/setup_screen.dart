import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:block_flutter/block_flutter.dart';
import '../providers/connection_provider.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController(text: '我的节点');
  final _addressCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _ipfsCtrl = TextEditingController();
  bool _testing = false;
  bool _keyVisible = false;
  String? _testError;

  @override
  void initState() {
    super.initState();
    _ipfsCtrl.text = context.read<ConnectionProvider>().ipfsEndpoint ?? '';
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _addressCtrl.dispose();
    _keyCtrl.dispose();
    _ipfsCtrl.dispose();
    super.dispose();
  }

  Future<void> _testAndSave() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _testing = true; _testError = null; });

    final connection = ConnectionModel(
      name: _nameCtrl.text.trim(),
      address: _addressCtrl.text.trim().replaceAll(RegExp(r'/$'), ''),
      keyBase64: _keyCtrl.text.trim(),
      status: ConnectionStatus.connecting,
    );

    try {
      final api = NodeApi(connection: connection);
      await api.getSignature();

      final nodeData = await ApiClient(connection: connection).postToBridge(
        protocol: 'open',
        routing: '/node/node',
        data: const {},
      );

      if (!mounted) return;
      final provider = context.read<ConnectionProvider>();
      await provider.addConnection(connection.copyWith(
        status: ConnectionStatus.connected,
        nodeData: nodeData,
      ));

      final ipfs = _ipfsCtrl.text.trim();
      if (ipfs.isNotEmpty) await provider.setIpfsEndpoint(ipfs);

      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      setState(() => _testError = '连接失败：$e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _saveIpfsOnly() async {
    final ipfs = _ipfsCtrl.text.trim();
    await context.read<ConnectionProvider>().setIpfsEndpoint(ipfs.isEmpty ? null : ipfs);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('IPFS 地址已保存')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ConnectionProvider>();
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('节点设置')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── 图片服务地址 ──
            _SectionLabel(label: '图片服务'),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _CardRow(
                    icon: Icons.link_rounded,
                    iconColor: cs.tertiary,
                    child: TextField(
                      controller: _ipfsCtrl,
                      decoration: const InputDecoration(
                        labelText: 'IPFS 端点',
                        hintText: 'http://192.168.1.100:8080',
                        border: InputBorder.none,
                        isDense: true,
                      ),
                      keyboardType: TextInputType.url,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonal(
                      onPressed: _saveIpfsOnly,
                      child: const Text('保存'),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ── 已配置节点 ──
            if (provider.connections.isNotEmpty) ...[
              _SectionLabel(label: '已配置节点'),
              ...provider.connections.asMap().entries.map((e) {
                final i = e.key;
                final c = e.value;
                final isActive = provider.activeConnection?.address == c.address;
                return _NodeCard(
                  connection: c,
                  isActive: isActive,
                  onSwitch: isActive ? null : () => provider.setActive(i),
                  onDelete: () => _confirmDelete(context, i, c.name),
                );
              }),
              const SizedBox(height: 20),
            ],

            // ── 添加节点 ──
            _SectionLabel(label: '添加节点'),
            _Card(
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    _CardRow(
                      icon: Icons.label_outline_rounded,
                      iconColor: cs.primary,
                      child: TextFormField(
                        controller: _nameCtrl,
                        decoration: const InputDecoration(
                          labelText: '节点名称',
                          border: InputBorder.none,
                          isDense: true,
                        ),
                        validator: (v) =>
                            v == null || v.trim().isEmpty ? '请输入名称' : null,
                      ),
                    ),
                    _Divider(),
                    _CardRow(
                      icon: Icons.dns_rounded,
                      iconColor: cs.primary,
                      child: TextFormField(
                        controller: _addressCtrl,
                        decoration: const InputDecoration(
                          labelText: '节点地址',
                          hintText: 'http://192.168.1.100:8080',
                          border: InputBorder.none,
                          isDense: true,
                        ),
                        keyboardType: TextInputType.url,
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return '请输入地址';
                          if (!v.trim().startsWith('http')) return '地址需以 http:// 开头';
                          return null;
                        },
                      ),
                    ),
                    _Divider(),
                    _CardRow(
                      icon: Icons.key_rounded,
                      iconColor: cs.primary,
                      child: TextFormField(
                        controller: _keyCtrl,
                        obscureText: !_keyVisible,
                        decoration: InputDecoration(
                          labelText: 'AES 密钥（Base64）',
                          border: InputBorder.none,
                          isDense: true,
                          suffixIcon: IconButton(
                            icon: Icon(
                              _keyVisible
                                  ? Icons.visibility_off_rounded
                                  : Icons.visibility_rounded,
                              size: 18,
                            ),
                            onPressed: () =>
                                setState(() => _keyVisible = !_keyVisible),
                          ),
                        ),
                        validator: (v) =>
                            v == null || v.trim().isEmpty ? '请输入密钥' : null,
                      ),
                    ),
                    if (_testError != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cs.errorContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline_rounded,
                                color: cs.onErrorContainer, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(_testError!,
                                  style: TextStyle(
                                      color: cs.onErrorContainer, fontSize: 13)),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _testing ? null : _testAndSave,
                        icon: _testing
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.check_circle_outline_rounded),
                        label: Text(_testing ? '连接中...' : '测试并保存'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, int index, String name) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('删除节点'),
        content: Text('确定要删除节点「$name」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () {
              Navigator.pop(context);
              context.read<ConnectionProvider>().removeConnection(index);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}

// ── 节点卡片 ──────────────────────────────────────────────────

class _NodeCard extends StatelessWidget {
  const _NodeCard({
    required this.connection,
    required this.isActive,
    required this.onDelete,
    this.onSwitch,
  });

  final ConnectionModel connection;
  final bool isActive;
  final VoidCallback? onSwitch;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isActive
            ? cs.primaryContainer.withValues(alpha: 0.45)
            : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isActive
              ? cs.primary.withValues(alpha: 0.35)
              : cs.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: isActive
                    ? cs.primary
                    : cs.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Icon(
                isActive ? Icons.wifi_rounded : Icons.wifi_off_rounded,
                size: 18,
                color: isActive ? Colors.white : cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        connection.name,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: isActive
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: isActive
                              ? cs.onPrimaryContainer
                              : cs.onSurface,
                        ),
                      ),
                      if (isActive) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: cs.primary,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '当前',
                            style: TextStyle(
                                fontSize: 10,
                                color: cs.onPrimary,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    connection.address,
                    style: TextStyle(
                        fontSize: 12, color: cs.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (onSwitch != null)
              TextButton(
                onPressed: onSwitch,
                style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact),
                child: const Text('切换'),
              ),
            IconButton(
              icon: Icon(Icons.delete_outline_rounded,
                  color: cs.error, size: 20),
              visualDensity: VisualDensity.compact,
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

// ── 通用组件 ──────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: cs.primary,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: cs.outlineVariant.withValues(alpha: 0.4)),
      ),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }
}

class _CardRow extends StatelessWidget {
  const _CardRow({
    required this.icon,
    required this.iconColor,
    required this.child,
  });

  final IconData icon;
  final Color iconColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: 18, color: iconColor),
        const SizedBox(width: 12),
        Expanded(child: child),
      ],
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Divider(
      height: 20,
      indent: 30,
      color: cs.outlineVariant.withValues(alpha: 0.5),
    );
  }
}
