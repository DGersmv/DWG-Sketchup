# dxf_parser.rb - DXF parser for topo survey data
# Extracts: ARC/CIRCLE centers, LWPOLYLINE/POLYLINE vertices,
#           LINE/POINT/INSERT positions, TEXT/MTEXT/ATTRIB content

module MeshFromPoints
  class DxfParser
    GEOM_ENTITIES = %w[ARC CIRCLE LWPOLYLINE POLYLINE LINE POINT INSERT
                       TEXT MTEXT ATTRIB ATTDEF].freeze

    # @param path [String] path to DXF file
    # @return [Hash] {
    #   layers:   [String, ...],
    #   geometry: [{ type:, layer:, x:, y: (, value:) }, ...],
    #   centroid: [cx, cy]
    # }
    def self.parse(path)
      result = { layers: [], geometry: [], centroid: [0.0, 0.0] }
      return result unless File.exist?(path)

      pairs = read_pairs(path)
      return result if pairs.empty?

      geometry = []
      layers   = {}

      n = pairs.size
      i = find_entities_section(pairs)
      return result if i.nil?

      in_polyline       = false
      polyline_layer    = ''
      lw_first_taken    = false

      while i < n
        code, val = pairs[i]

        # End of ENTITIES section
        if code == 0 && val == 'ENDSEC'
          break
        end

        # New entity starts
        unless code == 0 && GEOM_ENTITIES.include?(val)
          i += 1
          next
        end

        entity_type = val
        i += 1

        # Collect all group codes until the next entity or section end
        props = Hash.new { |h, k| h[k] = [] }
        while i < n
          c, v = pairs[i]
          break if c == 0
          props[c] << v
          i += 1
        end

        layer = props[8].first.to_s.strip
        layer = '0' if layer.empty?
        layers[layer] = true

        case entity_type
        when 'POLYLINE'
          in_polyline    = true
          polyline_layer = layer
          # vertices come as separate VERTEX entities - handled in next iterations

        when 'VERTEX'
          if in_polyline
            x = props[10].first.to_f
            y = props[20].first.to_f
            z = props[30].first.to_f rescue 0.0
            geometry << { type: :polyline, layer: polyline_layer, x: x, y: y, z: z }
          end

        when 'SEQEND'
          in_polyline = false

        when 'ARC', 'CIRCLE'
          in_polyline = false
          x = props[10].first.to_f
          y = props[20].first.to_f
          geometry << { type: :arc, layer: layer, x: x, y: y }

        when 'LWPOLYLINE'
          in_polyline = false
          xs = props[10]
          ys = props[20]
          elev = props[38].first.to_f rescue 0.0
          xs.each_with_index do |xv, idx|
            g = { type: :polyline, layer: layer,
                  x: xv.to_f, y: (ys[idx] || '0').to_f }
            g[:z] = elev
            geometry << g
          end

        when 'LINE'
          in_polyline = false
          x1 = props[10].first.to_f
          y1 = props[20].first.to_f
          z1 = (props[30].first.to_f rescue 0.0)
          x2 = (props[11].first.to_f rescue x1)
          y2 = (props[21].first.to_f rescue y1)
          z2 = (props[31].first.to_f rescue z1)
          geometry << { type: :line_segment, layer: layer,
                        x1: x1, y1: y1, z1: z1, x2: x2, y2: y2, z2: z2 }

        when 'POINT', 'INSERT'
          in_polyline = false
          x = props[10].first.to_f
          y = props[20].first.to_f
          geometry << { type: :point, layer: layer, x: x, y: y }

        when 'TEXT', 'ATTDEF', 'ATTRIB'
          in_polyline = false
          x    = props[10].first.to_f
          y    = props[20].first.to_f
          text = props[1].first.to_s.strip
          geometry << { type: :text, layer: layer, x: x, y: y, value: text } unless text.empty?

        when 'MTEXT'
          in_polyline = false
          x    = props[10].first.to_f
          y    = props[20].first.to_f
          # Code 3 chunks precede code 1 and are concatenated
          raw  = (props[3] + props[1]).join('')
          text = strip_mtext(raw).strip
          geometry << { type: :text, layer: layer, x: x, y: y, value: text } unless text.empty?
        end
      end

      # Subtract centroid to handle large geodetic coordinates
      unless geometry.empty?
        all_x, all_y = [], []
        geometry.each do |g|
          case g[:type]
          when :line_segment
            all_x << g[:x1] << g[:x2]
            all_y << g[:y1] << g[:y2]
          when :polyline, :arc, :point, :text
            all_x << g[:x] if g.key?(:x)
            all_y << g[:y] if g.key?(:y)
          end
        end
        cx = all_x.empty? ? 0.0 : all_x.sum / all_x.size.to_f
        cy = all_y.empty? ? 0.0 : all_y.sum / all_y.size.to_f
        geometry.each do |g|
          case g[:type]
          when :line_segment
            g[:x1] -= cx; g[:y1] -= cy; g[:x2] -= cx; g[:y2] -= cy
          when :polyline, :arc, :point, :text
            g[:x] -= cx if g.key?(:x); g[:y] -= cy if g.key?(:y)
          end
        end
        result[:centroid] = [cx, cy]
      end

      result[:layers]   = layers.keys.sort
      result[:geometry] = geometry
      result
    end

    # -------------------------------------------------------------------------
    private

    def self.find_entities_section(pairs)
      n = pairs.size
      i = 0
      while i < n
        code, val = pairs[i]
        if code == 0 && val == 'SECTION' && i + 1 < n && pairs[i + 1][1] == 'ENTITIES'
          return i + 2  # skip [0,SECTION] and [2,ENTITIES]
        end
        i += 1
      end
      nil
    end

    def self.read_pairs(path)
      content = try_read(path)
      return [] unless content

      lines = content.split(/\r?\n/)
      pairs = []
      idx = 0
      while idx + 1 < lines.size
        code_str = lines[idx].strip
        val      = lines[idx + 1].rstrip
        pairs << [code_str.to_i, val]
        idx += 2
      end
      pairs
    end

    def self.try_read(path)
      ['UTF-8', 'Windows-1251', 'ISO-8859-1'].each do |enc|
        begin
          content = File.read(path, encoding: "#{enc}:UTF-8",
                              invalid: :replace, undef: :replace, replace: '?')
          return content
        rescue
          nil
        end
      end
      File.read(path, encoding: 'binary') rescue nil
    end

    def self.strip_mtext(str)
      str = str.gsub(/\\[PpNn]/, ' ')
      str = str.gsub(/\{\\[^}]*\}/, '')
      str = str.gsub(/\\[A-Za-z][^;]*;/, '')
      str = str.gsub(/\\~/, ' ')
      str = str.gsub(/[{}]/, '')
      str.strip
    end
  end
end
