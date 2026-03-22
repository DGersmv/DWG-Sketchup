// Copyright 2025 DWG-mesh Plugin. Options for DXF/DWG topo import.

#ifndef DWGMESH_DWG_OPTIONS_HPP
#define DWGMESH_DWG_OPTIONS_HPP

#include <string>

struct DwgOptions {
  std::string arc_layer;
  std::string text_layer;
  double radius_mm = 3000.0;
  char decimal_separator = '.';
  bool add_contours = false;
  double contour_step_mm = 500.0;
};

#endif  // DWGMESH_DWG_OPTIONS_HPP
