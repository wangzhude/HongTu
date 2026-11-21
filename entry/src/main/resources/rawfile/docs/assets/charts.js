(function() {
  var style = getComputedStyle(document.documentElement);
  var accent = style.getPropertyValue('--accent').trim();
  var accent2 = style.getPropertyValue('--accent2').trim();
  var ink = style.getPropertyValue('--ink').trim();
  var muted = style.getPropertyValue('--muted').trim();
  var rule = style.getPropertyValue('--rule').trim();
  var bg2 = style.getPropertyValue('--bg2').trim();
  var warn = style.getPropertyValue('--warn').trim();
  var ok = style.getPropertyValue('--ok').trim();

  // --- Chart 1: Workload Estimation (Bar Chart) ---
  var chart1El = document.getElementById('chart-workload');
  if (chart1El) {
    var chart1 = echarts.init(chart1El, null, { renderer: 'svg' });
    chart1.setOption({
      animation: false,
      tooltip: {
        trigger: 'axis',
        axisPointer: { type: 'shadow' },
        appendToBody: true,
        backgroundColor: bg2,
        borderColor: rule,
        textStyle: { color: ink, fontSize: 13 },
        formatter: function(params) {
          var p = params[0];
          return p.name + '<br/>预估工时: <strong>' + p.value + ' 人天</strong>';
        }
      },
      grid: { left: '8%', right: '8%', top: '15%', bottom: '15%' },
      xAxis: {
        type: 'category',
        data: ['数据库核心', '验证引擎', '渲染引擎', 'Qt UI 层\n(方案B)', '脚本接口层'],
        axisLine: { lineStyle: { color: rule } },
        axisLabel: { color: muted, fontSize: 12, interval: 0 },
        axisTick: { show: false }
      },
      yAxis: {
        type: 'value',
        name: '人天',
        nameTextStyle: { color: muted, fontSize: 12 },
        axisLine: { show: false },
        axisLabel: { color: muted, fontSize: 12 },
        splitLine: { lineStyle: { color: rule, type: 'dashed' } }
      },
      series: [{
        type: 'bar',
        data: [
          { value: 5, itemStyle: { color: ok } },
          { value: 3, itemStyle: { color: ok } },
          { value: 10, itemStyle: { color: accent2 } },
          { value: 20, itemStyle: { color: accent2 } },
          { value: 30, itemStyle: { color: warn } }
        ],
        barWidth: '50%',
        label: {
          show: true,
          position: 'top',
          color: ink,
          fontSize: 13,
          fontWeight: 600,
          formatter: '{c} 天'
        },
        itemStyle: { borderRadius: [6, 6, 0, 0] }
      }]
    });
    window.addEventListener('resize', function() { chart1.resize(); });
  }

  // --- Chart 2: Project Gantt Chart ---
  var chart2El = document.getElementById('chart-gantt');
  if (chart2El) {
    var chart2 = echarts.init(chart2El, null, { renderer: 'svg' });

    var phases = [
      { name: '交叉编译环境搭建', phase: 1, start: 0, duration: 0.5 },
      { name: 'C++ 核心 NAPI 编译', phase: 1, start: 0.5, duration: 1 },
      { name: 'Qt-OHOS UI 适配', phase: 1, start: 1, duration: 1.5 },
      { name: '全量汉化 + 智能加载', phase: 1, start: 2, duration: 1 },
      { name: 'ArkUI 导航重构', phase: 2, start: 3, duration: 1.5 },
      { name: '图层可视化 + 属性面板', phase: 2, start: 4, duration: 1.5 },
      { name: '触屏/手写笔适配', phase: 2, start: 5, duration: 1 },
      { name: 'DRC/LVS 功能对接', phase: 2, start: 5.5, duration: 1.5 },
      { name: '万能卡片 + 跨设备流转', phase: 3, start: 7, duration: 2 },
      { name: '端侧 AI 辅助', phase: 3, start: 8, duration: 2 },
      { name: 'Python 解释器交叉编译', phase: 3, start: 7, duration: 3 },
      { name: '新手引导 + 帮助文档', phase: 3, start: 9, duration: 2 }
    ];

    var phaseColors = { 1: accent, 2: accent2, 3: warn };

    chart2.setOption({
      animation: false,
      tooltip: {
        trigger: 'item',
        appendToBody: true,
        backgroundColor: bg2,
        borderColor: rule,
        textStyle: { color: ink, fontSize: 13 },
        formatter: function(params) {
          var d = params.data;
          return d.name + '<br/>阶段: 第' + d.phase + '阶段<br/>开始: 第' + d.start + '周<br/>时长: ' + d.duration + '周';
        }
      },
      grid: { left: '25%', right: '8%', top: '10%', bottom: '12%' },
      xAxis: {
        type: 'value',
        name: '周',
        nameTextStyle: { color: muted, fontSize: 12 },
        min: 0,
        max: 13,
        interval: 1,
        axisLine: { lineStyle: { color: rule } },
        axisLabel: { color: muted, fontSize: 12 },
        splitLine: { lineStyle: { color: rule, type: 'dashed' } }
      },
      yAxis: {
        type: 'category',
        data: phases.map(function(p) { return p.name; }).reverse(),
        axisLine: { lineStyle: { color: rule } },
        axisLabel: { color: ink, fontSize: 12 },
        axisTick: { show: false }
      },
      series: [{
        type: 'custom',
        renderItem: function(params, api) {
          var categoryIndex = api.value(0);
          var start = api.coord([api.value(1), categoryIndex]);
          var end = api.coord([api.value(2), categoryIndex]);
          var height = api.size([0, 1])[1] * 0.6;

          var rectShape = echarts.graphic.clipRectByRect(
            { x: start[0], y: start[1] - height / 2, width: end[0] - start[0], height: height },
            { x: params.coordSys.x, y: params.coordSys.y, width: params.coordSys.width, height: params.coordSys.height }
          );

          return rectShape && {
            type: 'rect',
            shape: rectShape,
            style: {
              fill: phaseColors[api.value(3)],
              stroke: bg2,
              lineWidth: 1,
              borderRadius: 4
            }
          };
        },
        encode: { x: [1, 2], y: 0 },
        data: phases.map(function(p, i) {
          return {
            name: p.name,
            value: [i, p.start, p.start + p.duration, p.phase, p.start, p.duration],
            phase: p.phase,
            start: p.start,
            duration: p.duration
          };
        }).reverse()
      }],
      legend: {
        top: 0,
        right: '5%',
        data: [
          { name: '第一阶段: 基础移植', icon: 'rect' },
          { name: '第二阶段: ArkUI重写', icon: 'rect' },
          { name: '第三阶段: 差异化+脚本', icon: 'rect' }
        ],
        textStyle: { color: muted, fontSize: 12 },
        itemWidth: 14,
        itemHeight: 14,
        itemGap: 15
      }
    });

    // Fix legend colors
    chart2.setOption({
      color: [accent, accent2, warn]
    });

    window.addEventListener('resize', function() { chart2.resize(); });
  }
})();
