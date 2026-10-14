/**
 * @schema 2.11
 * @input count: number = 72
 * @input color: color = #70D8C2
 */
const count = Math.max(12, Math.round(pencil.input.count));
const gap = 2;
const barWidth = (pencil.width - gap * (count - 1)) / count;
const nodes = [];
for (let i = 0; i < count; i++) {
  const level = .16 + .63 * Math.exp(-Math.pow((i - count * .22) / (count * .24), 2)) + .13 * Math.pow(Math.sin(i * .56), 2);
  const height = pencil.height * level;
  nodes.push({type: 'rectangle', name: 'FFT bin ' + (i + 1), x: i * (barWidth + gap), y: pencil.height - height, width: barWidth, height, fill: pencil.input.color});
}
return nodes;
