import { UiLayer, LayerGroup } from '../common/types';

export interface LayoutLayerPair { layerNumber: number; datatype: number; }

/** A coherent group of SKY130 drawing layers, never one coincidental layer number. */
export function hasSky130DisplaySignature(pairs: LayoutLayerPair[]): boolean {
  const required: number[] = [64, 65, 66, 68];
  for (const number of required) {
    if (!pairs.some((pair: LayoutLayerPair): boolean => pair.layerNumber === number && pair.datatype === 20)) return false;
  }
  return true;
}

/** Display defaults only. Explicit layer profiles and saved geometry remain independent. */
export function defaultLayoutLayer(layerNumber: number, datatype: number,
  elementCount: number, fallbackColor: string, sky130: boolean): UiLayer {
  const layer: UiLayer = { layerNumber, datatype, elementCount, color: fallbackColor,
    chineseName: `图层${layerNumber}`, englishName: `L${layerNumber}`,
    visible: true, group: LayerGroup.OTHER };
  if (!sky130) return layer;
  let name: string = '';
  let color: string = '#AEB6C2';
  let transparency: number = 70;
  if (layerNumber === 64) { name = 'N阱'; color = '#789775'; transparency = 90; layer.group = LayerGroup.DOPING; }
  if (layerNumber === 65) { name = '有源区'; color = '#329C62'; transparency = 78; layer.group = LayerGroup.DOPING; }
  if (layerNumber === 66) { name = '多晶硅'; color = '#CD4C47'; transparency = 66; }
  if (layerNumber === 67) { name = '局部互连'; color = '#B29A20'; transparency = 70; }
  if (layerNumber === 68) { name = '金属1'; color = '#285FC6'; transparency = 52; }
  if (layerNumber === 69) { name = '金属2'; color = '#E681AF'; transparency = 58; }
  if (layerNumber === 70) { name = '金属3'; color = '#25978C'; transparency = 54; }
  if (layerNumber === 71) { name = '金属4'; color = '#D18A32'; transparency = 54; }
  if (layerNumber === 72) { name = '金属5'; color = '#8162B4'; transparency = 54; }
  if (name.length === 0) {
    layer.color = color;
    layer.transparency = 86;
    layer.fillStyle = 'outline';
    return layer;
  }
  if (layerNumber >= 67 && layerNumber <= 72) layer.group = LayerGroup.INTERCONNECT;
  if (datatype === 44) {
    name = layerNumber === 66 ? '多晶硅接触' : (layerNumber === 67 ? '局部接触' : `${name}通孔`);
    transparency = 28; layer.group = LayerGroup.CONTACT;
  } else if (datatype === 16) {
    name += '引脚'; transparency = 35;
    layer.visible = false;
  } else if (datatype === 5 || datatype === 0) {
    name += '标注';
    layer.visible = false;
  } else if (datatype !== 20) {
    name += ` D${datatype}`;
  }
  layer.chineseName = name;
  layer.englishName = `SKY130 ${layerNumber}/${datatype}`;
  layer.color = color;
  layer.transparency = transparency;
  layer.fillStyle = layerNumber === 64 ? 'outline' : 'solid';
  layer.lineWidth = 0.6;
  return layer;
}
