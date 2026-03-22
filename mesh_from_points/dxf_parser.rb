# dxf_parser.rb - Parse DXF for arcs, polylines, text (elevation points)

module MeshFromPoints
  class DxfParser
    def self.parse(path)
      # TODO: Read DXF, collect arc centers, polyline first points, text (position + content)
      # Return { arcs: [[x,y],...], texts: [[x,y,str],...], layers: [] }
      []
    end
  end
end
