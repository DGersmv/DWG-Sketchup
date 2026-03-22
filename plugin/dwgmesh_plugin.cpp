// Copyright 2025 DWG-mesh Plugin.

#include "./dwgmesh_plugin.hpp"

std::string CDwgMeshPlugin::GetDescription() const {
  return "DWG/DXF Topo Files (*.dwg,*.dxf)";
}

bool CDwgMeshPlugin::ConvertToSkp(
    const std::string& input, const std::string& output_skp,
    SketchUpPluginProgressCallback* callback, void* reserved) {
  (void)output_skp;
  (void)callback;
  (void)reserved;
  // TODO: Read DXF/DWG, build topo mesh, save to output_skp
  return false;
}
