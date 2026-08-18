import 'package:flutter/material.dart';
import '../viewmodels/spider_classic_viewmodel.dart';
import '../viewmodels/tiara_raw_viewmodel.dart';
import 'dashboard_panel.dart';

class BrainLinkScreen extends StatefulWidget {
  const BrainLinkScreen({super.key});

  @override
  State<BrainLinkScreen> createState() => _BrainLinkScreenState();
}

class _BrainLinkScreenState extends State<BrainLinkScreen> {
  final SpiderClassicViewModel spiderClassicViewModel =
      SpiderClassicViewModel();
  final TiaraRawViewModel tiaraRawViewModel = TiaraRawViewModel();

  @override
  void initState() {
    super.initState();
    tiaraRawViewModel.attachSpider(spiderClassicViewModel);
  }

  @override
  void dispose() {
    spiderClassicViewModel.dispose();
    tiaraRawViewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BrainLink BCI'), centerTitle: true),
      body: DashboardPanel(
        spiderClassicViewModel: spiderClassicViewModel,
        tiaraRawViewModel: tiaraRawViewModel,
      ),
    );
  }
}
