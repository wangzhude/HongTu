import type { LayerStackPreview, LayerStackMesh, LayerStackVertex, LayerStackTriangle } from './LayerStackService';

/** Export the computed mesh itself in nm, never a bounding-box proxy. */
export class LayerStackExportService {
  private check(preview: LayerStackPreview): void {
    if (preview.unit !== 'nm' || !Number.isFinite(preview.precisionNm) || preview.precisionNm <= 0 ||
      !Array.isArray(preview.meshes) || preview.meshes.length === 0 || preview.meshes.length > 20000) throw new Error('没有完整可导出的层栈网格');
    let vertices: number = 0, triangles: number = 0, volume: number = 0;
    for (const mesh of preview.meshes) {
      if (!Array.isArray(mesh.vertices) || !Array.isArray(mesh.triangles) || mesh.vertices.length < 4 || mesh.triangles.length < 4 ||
        !Number.isFinite(mesh.volumeNm3) || mesh.volumeNm3 <= 0) throw new Error('物理网格不完整');
      vertices += mesh.vertices.length; triangles += mesh.triangles.length; volume += mesh.volumeNm3;
      if (vertices > 1000000 || triangles > 2000000) throw new Error('网格导出超过完整预算');
      for (const point of mesh.vertices) if (![point.xNm, point.yNm, point.zNm].every((value: number): boolean => Number.isFinite(value))) throw new Error('网格含非有限坐标');
      for (const face of mesh.triangles) if (![face.a, face.b, face.c].every((at: number): boolean => Number.isSafeInteger(at) && at >= 0 && at < mesh.vertices.length) ||
        face.a === face.b || face.b === face.c || face.a === face.c) throw new Error('三角形索引损坏');
      const edges: Map<string, number[]> = new Map<string, number[]>();
      const origin: LayerStackVertex = mesh.vertices[0]; let signedVolume: number = 0, measuredArea: number = 0;
      for (const face of mesh.triangles) {
        for (const pair of [[face.a, face.b], [face.b, face.c], [face.c, face.a]]) {
          const low: number = Math.min(pair[0], pair[1]), high: number = Math.max(pair[0], pair[1]), key: string = `${low}/${high}`;
          const record: number[] = edges.get(key) ?? [0, 0]; record[0]++; record[1] += pair[0] === low ? 1 : -1; edges.set(key, record);
        }
        const a: LayerStackVertex = mesh.vertices[face.a], b: LayerStackVertex = mesh.vertices[face.b], c: LayerStackVertex = mesh.vertices[face.c];
        const ux: number = b.xNm - a.xNm, uy: number = b.yNm - a.yNm, uz: number = b.zNm - a.zNm;
        const vx: number = c.xNm - a.xNm, vy: number = c.yNm - a.yNm, vz: number = c.zNm - a.zNm;
        const nx: number = uy * vz - uz * vy, ny: number = uz * vx - ux * vz, nz: number = ux * vy - uy * vx;
        const area: number = Math.hypot(nx, ny, nz) / 2;
        if (!Number.isFinite(area) || area <= 0) throw new Error('导出网格包含退化三角形');
        measuredArea += area; signedVolume += ((a.xNm - origin.xNm) * nx + (a.yNm - origin.yNm) * ny + (a.zNm - origin.zNm) * nz) / 6;
      }
      for (const record of edges.values()) if (record[0] !== 2 || record[1] !== 0) throw new Error('导出网格没有闭合或面方向不一致');
      if (!Number.isFinite(signedVolume) || Math.abs(Math.abs(signedVolume) - mesh.volumeNm3) > Math.max(1, mesh.volumeNm3) * 1e-8 ||
        !Number.isFinite(mesh.surfaceAreaNm2) || Math.abs(measuredArea - mesh.surfaceAreaNm2) > Math.max(1, measuredArea) * 1e-8) throw new Error('导出网格实际体积或表面积与报告不一致');
    }
    if (!Number.isFinite(volume) || Math.abs(volume - preview.totalVolumeNm3) > Math.max(1, volume) * 1e-9) throw new Error('完整材料体积与网格列表不一致');
  }
  obj(preview: LayerStackPreview): string {
    this.check(preview);
    const lines: string[] = ['# HongTu physical LayerStack: coordinates in nm', `# XY precision ${preview.precisionNm} nm`, '# Material and process provenance are in the matching geometry JSON'];
    let base: number = 1;
    preview.meshes.forEach((mesh: LayerStackMesh, index: number): void => {
      // Do not interpolate user names into the OBJ syntax.
      lines.push(`o physical_mesh_${index}`, `# material ${JSON.stringify(mesh.materialId)}`, `# level ${JSON.stringify(mesh.levelId)}`);
      for (const point of mesh.vertices) lines.push(`v ${point.xNm} ${point.yNm} ${point.zNm}`);
      for (const face of mesh.triangles) lines.push(`f ${base + face.a} ${base + face.b} ${base + face.c}`);
      base += mesh.vertices.length;
    });
    return lines.join('\n') + '\n';
  }
  geometryJson(preview: LayerStackPreview): string {
    this.check(preview);
    return JSON.stringify({ schema: 'hongtu-physical-geometry/v1', unit: 'nm', model: preview,
      qualification: 'geometry-from-user-process-parameters' }, null, 2);
  }
  sectionJson(preview: LayerStackPreview): string {
    this.check(preview);
    if (!Array.isArray(preview.section) || !Number.isFinite(preview.sectionLengthNm) || preview.sectionLengthNm <= 0) throw new Error('尚未生成明确剖切线的截面');
    const line = preview.sectionLine, bounds = preview.boundsNm;
    if (line === undefined || bounds === undefined || !Number.isSafeInteger(preview.rootCellId) || preview.rootCellId < 0 ||
      !Number.isFinite(preview.dbuNm) || preview.dbuNm <= 0 ||
      ![line.startNm.x, line.startNm.y, line.endNm.x, line.endNm.y, bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].every((n: number): boolean => Number.isFinite(n)) ||
      !(bounds.minX < bounds.maxX && bounds.minY < bounds.maxY) ||
      Math.abs(Math.hypot(line.endNm.x - line.startNm.x, line.endNm.y - line.startNm.y) - preview.sectionLengthNm) > Math.max(1, preview.sectionLengthNm) * 1e-9) throw new Error('截面缺少有效源 Cell、DBU、ROI 或真实剖切线');
    return JSON.stringify({ schema: 'hongtu-physical-section/v1', unit: 'nm', stackJson: preview.stackJson,
      boundsNm: preview.boundsNm, sectionLine: preview.sectionLine, rootCellId: preview.rootCellId, dbuNm: preview.dbuNm, sourceCoordinatePolicy: preview.sourceCoordinatePolicy,
      sectionLengthNm: preview.sectionLengthNm, precisionNm: preview.precisionNm,
      polygons: preview.section, warnings: preview.warnings }, null, 2);
  }
}
export const layerStackExportService: LayerStackExportService = new LayerStackExportService();
