# DXF Topo Mesh - triangulated TIN mesh from DXF topo survey
# Loader

require 'sketchup'

unless file_loaded?(__FILE__)
  ext = SketchupExtension.new('DXF Topo Mesh', 'mesh_from_points/main')
  ext.description = 'Create triangulated TIN mesh from a DXF topo survey (arcs/points + elevation labels). Supports direct DXF file import.'
  ext.version = '2.0.0'
  ext.creator = 'DWG-mesh'
  Sketchup.register_extension(ext, true)
  file_loaded(__FILE__)
end
