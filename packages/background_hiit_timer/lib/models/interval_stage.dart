enum IntervalStage {
  getReady('Get Ready'),
  warmup('Warmup'),
  work('Work'),
  rest('Rest'),
  breakTime('Break'),
  cooldown('Cooldown');

  const IntervalStage(this.label);
  final String label;

  static String fromLegacyName(String name) => values
      .firstWhere((stage) => stage.label == name, orElse: () => work)
      .name;
}
