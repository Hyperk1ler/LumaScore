/**
 * @schema 2.11
 * @input count: number = 120
 * @input color: color = #70D8C2
 */
const count = Math.max(12, Math.round(pencil.input.count));
const gap = 1;
const barWidth = (pencil.width - gap * (count - 1)) / count;
const nodes = [];
for (let i = 0; i < count; i++) {
  const height = pencil.height * (.16 + .76 * Math.abs(Math.sin(i * .36) * Math.cos(i * .11)));
  nodes.push({type: 'rectangle', name: 'Waveform sample ' + (i + 1), x: i * (barWidth + gap), y: (pencil.height - height) / 2, width: barWidth, height, fill: i < 35 ? pencil.input.color : '#43586D'});
}
return nodes;
