import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'ble_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) => BLEService(),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  @override
  void initState() {
    super.initState();
    _loadThemePreference();
  }

  Future<void> _loadThemePreference() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool('isDarkMode') ?? true;
    setState(() {
      _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    });
  }

  Future<void> _toggleTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = _themeMode == ThemeMode.dark;
    await prefs.setBool('isDarkMode', !isDark);
    setState(() {
      _themeMode = isDark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Thread Commissioner',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: HomePage(onToggleTheme: _toggleTheme),
    );
  }
}

class HomePage extends StatefulWidget {
  final VoidCallback onToggleTheme;

  const HomePage({super.key, required this.onToggleTheme});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  bool _showOnboarding = true;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _checkOnboarding();
    _requestPermissions();

    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  Future<void> _checkOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    final hasSeenOnboarding = prefs.getBool('hasSeenOnboarding') ?? false;
    setState(() {
      _showOnboarding = !hasSeenOnboarding;
    });
  }

  Future<void> _completeOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('hasSeenOnboarding', true);
    setState(() {
      _showOnboarding = false;
    });
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.camera,
    ].request();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_showOnboarding) {
      return OnboardingScreen(onComplete: _completeOnboarding);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Thread Commissioner'),
        actions: [
          Consumer<BLEService>(
            builder: (context, bleService, _) => IconButton(
              icon: Icon(
                bleService.isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                color: bleService.isConnected ? Colors.green : null,
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const DiagnosticsPage()),
                );
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => SettingsPage(onToggleTheme: widget.onToggleTheme)),
              );
            },
          ),
        ],
      ),
      body: Consumer<BLEService>(
        builder: (context, bleService, _) {
          return Column(
            children: [
              _buildConnectionStatus(bleService),
              Expanded(
                child: bleService.isConnected
                    ? _buildMainContent(bleService)
                    : _buildDisconnectedState(bleService),
              ),
              _buildLogsSection(bleService),
            ],
          );
        },
      ),
    );
  }

  Widget _buildConnectionStatus(BLEService bleService) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bleService.isConnected
            ? Colors.green.withOpacity(0.1)
            : Colors.orange.withOpacity(0.1),
        border: Border(
          bottom: BorderSide(
            color: bleService.isConnected ? Colors.green : Colors.orange,
            width: 2,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            bleService.isConnected ? Icons.check_circle : Icons.warning,
            color: bleService.isConnected ? Colors.green : Colors.orange,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bleService.isConnected ? 'Connected' : 'Disconnected',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                if (bleService.isConnected)
                  Text(
                    '${bleService.deviceName} • RSSI: ${bleService.rssi} dBm',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          if (bleService.isConnected)
            _buildSignalStrength(bleService.rssi),
        ],
      ),
    );
  }

  Widget _buildSignalStrength(int rssi) {
    IconData icon;
    Color color;

    if (rssi >= -60) {
      icon = Icons.signal_cellular_alt;
      color = Colors.green;
    } else if (rssi >= -75) {
      icon = Icons.signal_cellular_alt_2_bar;
      color = Colors.orange;
    } else {
      icon = Icons.signal_cellular_alt_1_bar;
      color = Colors.red;
    }

    return Icon(icon, color: color);
  }

  Widget _buildDisconnectedState(BLEService bleService) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ScaleTransition(
            scale: _pulseAnimation,
            child: Icon(
              Icons.bluetooth_searching,
              size: 80,
              color: Theme.of(context).colorScheme.primary.withOpacity(0.5),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'No Device Connected',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'Scan for Bridge ESP to begin',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
            ),
          ),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            onPressed: bleService.isScanning ? null : () => bleService.startScan(),
            icon: bleService.isScanning
                ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
                : const Icon(Icons.search),
            label: Text(bleService.isScanning ? 'Scanning...' : 'Scan for Devices'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainContent(BLEService bleService) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildQuickActions(bleService),
          const SizedBox(height: 16),
          _buildQRScanButton(),
          const SizedBox(height: 16),
          _buildCommissionHistory(bleService),
        ],
      ),
    );
  }

  Widget _buildQuickActions(BLEService bleService) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Quick Actions',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ActionChip(
                  avatar: const Icon(Icons.qr_code_scanner, size: 18),
                  label: const Text('Scan QR'),
                  onPressed: () => _showQRScanner(context),
                ),
                ActionChip(
                  avatar: const Icon(Icons.code, size: 18),
                  label: const Text('Manual Command'),
                  onPressed: () => _showManualCommandDialog(context, bleService),
                ),
                ActionChip(
                  avatar: const Icon(Icons.history, size: 18),
                  label: const Text('View History'),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const HistoryPage()),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQRScanButton() {
    return Card(
      child: InkWell(
        onTap: () => _showQRScanner(context),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.qr_code_scanner,
                  size: 32,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Commission New Device',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Scan QR code to add device to network',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios, size: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCommissionHistory(BLEService bleService) {
    if (bleService.commissionHistory.isEmpty) {
      return const SizedBox.shrink();
    }

    final recentDevices = bleService.commissionHistory.reversed.take(3).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Recent Commissions',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const HistoryPage()),
                    );
                  },
                  child: const Text('View All'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...recentDevices.map((device) => ListTile(
              dense: true,
              leading: Icon(
                device.success ? Icons.check_circle : Icons.error,
                color: device.success ? Colors.green : Colors.red,
              ),
              title: Text(device.eui64),
              subtitle: Text(_formatTimestamp(device.timestamp)),
            )),
          ],
        ),
      ),
    );
  }

  Widget _buildLogsSection(BLEService bleService) {
    return Container(
      height: 200,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).dividerColor,
            width: 1,
          ),
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(
                  Icons.terminal,
                  size: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Console Logs',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.share, size: 18),
                  onPressed: () => _exportLogs(bleService),
                  tooltip: 'Export Logs',
                ),
                IconButton(
                  icon: const Icon(Icons.delete, size: 18),
                  onPressed: bleService.clearLogs,
                  tooltip: 'Clear Logs',
                ),
              ],
            ),
          ),
          Expanded(
            child: bleService.logs.isEmpty
                ? Center(
              child: Text(
                'No logs yet',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
                : ListView.builder(
              reverse: true,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: bleService.logs.length,
              itemBuilder: (context, index) {
                final log = bleService.logs[bleService.logs.length - 1 - index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    log,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _showQRScanner(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const QRScannerPage()),
    );
  }

  void _showManualCommandDialog(BuildContext context, BLEService bleService) {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send Manual Command'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Command',
            hintText: 'e.g., add 1234567890abcdef mypassword',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                bleService.sendCustomCommand(controller.text);
                HapticFeedback.mediumImpact();
                Navigator.pop(context);
              }
            },
            child: const Text('Send'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportLogs(BLEService bleService) async {
    try {
      final logs = bleService.exportLogs();
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/thread_commissioner_logs.txt');
      await file.writeAsString(logs);

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Thread Commissioner Logs',
      );

      HapticFeedback.lightImpact();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error exporting logs: $e')),
        );
      }
    }
  }

  String _formatTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inDays < 1) {
      return '${difference.inHours}h ago';
    } else {
      return '${difference.inDays}d ago';
    }
  }
}

class QRScannerPage extends StatefulWidget {
  const QRScannerPage({super.key});

  @override
  State<QRScannerPage> createState() => _QRScannerPageState();
}

class _QRScannerPageState extends State<QRScannerPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _isProcessing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleBarcode(BarcodeCapture capture) async {
    if (_isProcessing) return;

    final barcode = capture.barcodes.firstOrNull;
    if (barcode?.rawValue == null) return;

    setState(() => _isProcessing = true);
    HapticFeedback.mediumImpact();

    final data = barcode!.rawValue!;
    final parts = data.split('|');

    if (parts.length >= 2) {
      final eui64 = parts[0];
      final pskd = parts[1];

      if (!mounted) return;
      Navigator.pop(context);

      final bleService = Provider.of<BLEService>(context, listen: false);
      await bleService.commissionDevice(eui64, pskd);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Commissioning device $eui64'),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Invalid QR code format. Expected: EUI64|PSKd'),
          backgroundColor: Colors.red,
        ),
      );
      setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan QR Code'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            icon: const Icon(Icons.flip_camera_ios),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _handleBarcode,
          ),
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Text(
                  'Align QR code within frame',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsPage extends StatelessWidget {
  final VoidCallback onToggleTheme;

  const SettingsPage({super.key, required this.onToggleTheme});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Consumer<BLEService>(
        builder: (context, bleService, _) => ListView(
          children: [
            SwitchListTile(
              title: const Text('Auto-Reconnect'),
              subtitle: const Text('Automatically reconnect when connection is lost'),
              value: bleService.autoReconnect,
              onChanged: bleService.setAutoReconnect,
            ),
            ListTile(
              title: const Text('Toggle Theme'),
              subtitle: const Text('Switch between light and dark mode'),
              leading: const Icon(Icons.brightness_6),
              onTap: onToggleTheme,
            ),
            ListTile(
              title: const Text('Update Secret Key'),
              subtitle: const Text('Change HMAC signing key'),
              leading: const Icon(Icons.key),
              onTap: () => _showUpdateKeyDialog(context, bleService),
            ),
            ListTile(
              title: const Text('Clear History'),
              subtitle: const Text('Remove all commissioned device records'),
              leading: const Icon(Icons.delete_sweep),
              onTap: () {
                bleService.clearHistory();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('History cleared')),
                );
              },
            ),
            const Divider(),
            ListTile(
              title: const Text('About'),
              subtitle: const Text('Thread Commissioner v1.0.0'),
              leading: const Icon(Icons.info_outline),
            ),
          ],
        ),
      ),
    );
  }

  void _showUpdateKeyDialog(BuildContext context, BLEService bleService) {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Update Secret Key'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'New Secret Key',
            hintText: 'Enter new HMAC key',
          ),
          obscureText: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                await bleService.updateSecretKey(controller.text);
                if (!context.mounted) return;
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Secret key updated')),
                );
              }
            },
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }
}

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Commission History')),
      body: Consumer<BLEService>(
        builder: (context, bleService, _) {
          if (bleService.commissionHistory.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.history, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('No devices commissioned yet'),
                ],
              ),
            );
          }

          return ListView.builder(
            itemCount: bleService.commissionHistory.length,
            itemBuilder: (context, index) {
              final device = bleService.commissionHistory.reversed.toList()[index];
              return ListTile(
                leading: Icon(
                  device.success ? Icons.check_circle : Icons.error,
                  color: device.success ? Colors.green : Colors.red,
                ),
                title: Text(device.eui64),
                subtitle: Text(device.timestamp.toString()),
                trailing: Chip(
                  label: Text(device.success ? 'Success' : 'Failed'),
                  backgroundColor: device.success
                      ? Colors.green.withOpacity(0.2)
                      : Colors.red.withOpacity(0.2),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class DiagnosticsPage extends StatelessWidget {
  const DiagnosticsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BLE Diagnostics')),
      body: Consumer<BLEService>(
        builder: (context, bleService, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildInfoCard(
              context,
              'Connection Status',
              bleService.isConnected ? 'Connected' : 'Disconnected',
              Icons.bluetooth,
              bleService.isConnected ? Colors.green : Colors.red,
            ),
            _buildInfoCard(
              context,
              'Device Name',
              bleService.deviceName,
              Icons.devices,
              Colors.blue,
            ),
            _buildInfoCard(
              context,
              'Signal Strength (RSSI)',
              '${bleService.rssi} dBm',
              Icons.signal_cellular_alt,
              _getRssiColor(bleService.rssi),
            ),
            _buildInfoCard(
              context,
              'Service UUID',
              BLEService.serviceUuid,
              Icons.settings_input_component,
              Colors.purple,
            ),
            _buildInfoCard(
              context,
              'Characteristic UUID',
              BLEService.charUuid,
              Icons.settings_input_antenna,
              Colors.orange,
            ),
            _buildInfoCard(
              context,
              'Total Commissioned',
              '${bleService.commissionHistory.length} devices',
              Icons.history,
              Colors.teal,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard(BuildContext context, String title, String value, IconData icon, Color color) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(title),
        subtitle: Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }

  Color _getRssiColor(int rssi) {
    if (rssi >= -60) return Colors.green;
    if (rssi >= -75) return Colors.orange;
    return Colors.red;
  }
}

class OnboardingScreen extends StatefulWidget {
  final VoidCallback onComplete;

  const OnboardingScreen({super.key, required this.onComplete});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (page) => setState(() => _currentPage = page),
                children: [
                  _buildPage(
                    Icons.bluetooth_searching,
                    'Connect to Bridge ESP',
                    'Scan and connect to your BLE-to-UART bridge device',
                    Colors.blue,
                  ),
                  _buildPage(
                    Icons.qr_code_scanner,
                    'Scan Device QR Code',
                    'Use your camera to scan the QR code on Thread devices',
                    Colors.green,
                  ),
                  _buildPage(
                    Icons.security,
                    'Secure Commissioning',
                    'Commands are signed with HMAC-SHA256 for security',
                    Colors.purple,
                  ),
                  _buildPage(
                    Icons.history,
                    'Track Your Devices',
                    'View commission history and manage your Thread network',
                    Colors.orange,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (_currentPage > 0)
                    TextButton(
                      onPressed: () => _pageController.previousPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      ),
                      child: const Text('Back'),
                    )
                  else
                    const SizedBox(width: 80),
                  Row(
                    children: List.generate(
                      4,
                          (index) => Container(
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _currentPage == index
                              ? Theme.of(context).colorScheme.primary
                              : Colors.grey.withOpacity(0.3),
                        ),
                      ),
                    ),
                  ),
                  ElevatedButton(
                    onPressed: _currentPage == 3
                        ? widget.onComplete
                        : () => _pageController.nextPage(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    ),
                    child: Text(_currentPage == 3 ? 'Get Started' : 'Next'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPage(IconData icon, String title, String description, Color color) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 120, color: color),
          const SizedBox(height: 48),
          Text(
            title,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            description,
            style: Theme.of(context).textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}