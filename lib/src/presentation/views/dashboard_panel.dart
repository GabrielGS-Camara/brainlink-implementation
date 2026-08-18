import 'package:flutter/material.dart';
import '../viewmodels/spider_classic_viewmodel.dart';
import '../viewmodels/tiara_raw_viewmodel.dart';
import 'spider_classic_panel.dart';
import 'tiara_raw_panel.dart';

class DashboardPanel extends StatelessWidget {
  final SpiderClassicViewModel spiderClassicViewModel;
  final TiaraRawViewModel tiaraRawViewModel;

  const DashboardPanel({
    super.key,
    required this.spiderClassicViewModel,
    required this.tiaraRawViewModel,
  });

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ColoredBox(
            color: Colors.white,
            child: TabBar(
              labelColor: Colors.blue,
              unselectedLabelColor: Colors.grey,
              tabs: [
                Tab(icon: Icon(Icons.psychology), text: "Tiara"),
                Tab(icon: Icon(Icons.settings_input_antenna), text: "Aranha"),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                ListenableBuilder(
                  listenable: tiaraRawViewModel,
                  builder: (context, _) {
                    return TiaraRawPanel(viewModel: tiaraRawViewModel);
                  },
                ),
                ListenableBuilder(
                  listenable: spiderClassicViewModel,
                  builder: (context, _) {
                    return SpiderClassicPanel(
                      viewModel: spiderClassicViewModel,
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
