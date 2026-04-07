import 'package:flutter/material.dart';
import 'navigation_screen.dart';

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({Key? key}) : super(key: key);

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  final TextEditingController _ipController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('连接ESP32')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: _ipController,
              decoration: InputDecoration(
                labelText: 'ESP32 IP地址',
                hintText: '例如: 192.168.4.1',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                String ip = _ipController.text.trim();
                if (ip.isEmpty) ip = '192.168.4.1';
                Navigator.push(context, MaterialPageRoute(builder: (_) => NavigationScreen(espIP: ip)));
              },
              child: Text('开始导航'),
            ),
          ],
        ),
      ),
    );
  }
}