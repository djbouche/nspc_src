midifile = "nspc/smas-%02X.mid"

mapper = {
  # 1 => { #title
  #   program: { 0 => 36 },
  #   chtrans: { 0 => [-12] },
  # },
  # 2 => { #select
  #   program: { 0 => 38, 1 => 18, 2 => 18, 3 => 18, 4 => 0, 5 => 52, 6 => 52 },
  #   chtrans: { 4 => [-12] }
  # },
  # 3 => { #raceway
  #   program: { 0 => 38, 1 => 18, 2 => 18, 3 => 18, 4 => 61, 5 => 61 },
  #   chtrans: { 3 => [12], 4 => [-12, 0], 5 => [-12, 0] },
  # },
  # 18 => { #rainbow
  #   program: { 0 => 36, 1 => 18, 2 => 18, 3 => 18, 4 => 100, 5 => 30, 6 => 80 },
  #   chtrans: { 0 => [-12], 4 => [12] },
  # }
}

require "./binwriter"
require "./rom"

rom = ROM.from_file(ARGV[0] || 'smas-102.spc')
rom.set_base 0x100

bank_addr = ARGV[1] || 0xC000
bank_count = ARGV[2] || 10

cmd_len_table = [1,1,2,3,0,1,2,1,2,1,1,3,0,1,2,3,1,3,3,0,1,3,0,3,3,3,1]

rom.seek bank_addr

bank_entries = []

bank_count.times do |i|
  song_offset = rom.read_u16_le
  bank_entries << {offset: song_offset}
end

song_idx = [0]

song_idx.each do |sidx|
# bank_entries.each_with_index do |entry, songnum|
  entry = bank_entries[sidx]
  songnum = sidx
  puts "Ripping song %02X at %04X -> #{midifile % songnum}" % [songnum, bank_addr + entry[:offset]]

  rom.seek entry[:offset]

  events = []
  t = 0
  tempo = 120
  loops = 1

  patterns = []
  pattern_loop_index = nil

  while true
    pattern_offset = rom.read_u16_le
    if pattern_offset < 0x100
      pattern_loop_offset = rom.read_u16_le
      pattern_loop_index = (rom.read_u16_le - entry[:offset]) / 2
      break
    else
      patterns << {offset: pattern_offset}
    end
  end

  patterns.each_with_index do |pattern, pidx|
    rom.msg "Pattern %02X at %04X" % [pidx, pattern[:offset]]
    rom.seek pattern[:offset]
    tracks = (0...8).map { {offset: rom.read_u16_le } }
    pattern_length = nil
    note_length = 0x18
    note_gate = 0xF
    note_vel = 0x7
    tracks.each_with_index do |track, idx|
      next unless track[:offset] > 0
      pt = 0
      rom.msg "Track %02X at %04X" % [idx, track[:offset]]
      rom.seek track[:offset]
      channel = idx
      last_note = nil
      while pattern_length.nil? || pt < pattern_length
        cmd = rom.read_byte
        cmd_args = []

        if cmd >= 0xE0
          cmd_len = cmd_len_table[cmd - 0xE0]
          cmd_args = (0...cmd_len).map { rom.read_byte }
          rom.msg ("%02X " + ("%02X " * cmd_args.size)) % ([cmd] + cmd_args)
        end

        if cmd == 0x00
          rom.msg "End of Track"
          pattern_length = pt
          break
        elsif cmd < 0x80
          arg2 = rom.read_byte
          if arg2 > 0x7F
            rom.seek_rel -1
            arg2 = nil
            rom.msg "Length Change %02X" % [cmd]
          else
            rom.msg "Length Change %02X %02X" % [cmd, arg2]
          end
          note_length = cmd
        elsif cmd < 0xDF
          note_name = "%02X" % cmd
          if cmd == 0xC9 # note off
            if last_note
              events << { type: :note_off, channel: channel, timestamp: t + pt, note: last_note[:note], vel: 0 }
              last_note = nil
            end
            note_name = "Note Off"
          elsif cmd == 0xC8
            note_name = "Note Hold"
          else
            if last_note
              events << { type: :note_off, channel: channel, timestamp: t + pt, note: last_note[:note], vel: 0 }
              last_note = nil
            end
            note = cmd - 0x80
            vel = 100
            last_note = { type: :note_on, channel: channel, timestamp: t + pt, note: note, vel: vel }
            events << last_note
            oct = note / 12
            snote = note % 12
            name = "%s%d" % [["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"][snote], oct]
          end
          rom.msg "Note #{name}"
          pt += note_length
        else
          case cmd
          when 0xE0
            rom.msg "Patch %02X" % cmd_args
          when 0xE1
          when 0xE3
          when 0xE4
          when 0xE5
            rom.msg "Global Vol %02X" % cmd_args
          when 0xE7
          when 0xEA
          when 0xED
            rom.msg "Vol %02X" % cmd_args
          when 0xEF
          when 0xF4
          when 0xF5
          when 0xF7
          when 0xFA
          else
            rom.msg "Unhandled command (next bytes):"
            raise "%02X %02X %02X %02X" % (0...4).map { rom.read_byte }
          end
        end
      end
      rom.msg "Finished processing track"
    end
    t += pattern_length
  end

  # { channel: i, offset: a, timestamp: t }

  events.sort! { |a,b| a[:timestamp] <=> b[:timestamp] }

  # puts events
  last_t = 0

  BinWriter.open (midifile % songnum) do |f|
    f.write_str "MThd"
    f.write_u32_be 6
    f.write_u16_be 0
    f.write_u16_be 1
    f.write_u16_be 0x18
    f.write_str "MTrk"
    p = f.tell
    f.write_u32_be 0
    s = f.tell
    f.write_vlq 0
    f.write_byte 0xFF
    f.write_byte 0x51
    f.write_byte 0x03
    f.write_u24_be (60000000.0 / tempo.to_f).to_i

    (0..15).each do |i|
      f.write_vlq 0
      f.write_byte 0xB0 + i
      f.write_byte 0x65
      f.write_byte 0x00

      f.write_vlq 0
      f.write_byte 0xB0 + i
      f.write_byte 0x64
      f.write_byte 0x00

      f.write_vlq 0
      f.write_byte 0xB0 + i
      f.write_byte 0x06
      f.write_byte 0x0C

      f.write_vlq 0
      f.write_byte 0xB0 + i
      f.write_byte 0x38
      f.write_byte 0x00
    end

    events.each do |e|
      ch = e[:channel]

      cc = ch
      cc = 9 if ch == 10 || ch == 11

      case e[:type]
      when :note_off
        cht = [ch] #chtmap[ch] || [0]
        cht.each do |ct|
          ts = e[:timestamp] - last_t
          last_t = e[:timestamp]
          f.write_vlq ts
          f.write_byte 0x90 + cc
          note = e[:note] #(drummap[ch] && drummap[ch][e[:note]]) || e[:note]
   #      note += 15 if ch == 9
          f.write_byte note + ct
         f.write_byte 0
        end
      when :note_on
        cht = [ch] #chtmap[ch] || [0]
        cht.each do |ct|
          ts = e[:timestamp] - last_t
          last_t = e[:timestamp]
          f.write_vlq ts
          f.write_byte 0x90 + cc
          note = e[:note] # (drummap[ch] && drummap[ch][e[:note]]) || e[:note]
    #      note += 15 if ch == 9
          f.write_byte note + ct
        f.write_byte e[:vel]
        end
      when :cc
        unless cc == 9
          ts = e[:timestamp] - last_t
          last_t = e[:timestamp]
          f.write_vlq ts
          f.write_byte 0xB0 + cc
          f.write_byte e[:num]
          f.write_byte e[:val]
        end
      when :program
        ts = e[:timestamp] - last_t
        last_t = e[:timestamp]
        f.write_vlq ts
        f.write_byte 0xC0 + cc
        if cc == 9
          prg = 8
        else
          prg = progmap[e[:program]] || e[:program]
        end
        f.write_byte prg
      when :pitch
        pitch_int = e[:val] + 0x2000
        ts = e[:timestamp] - last_t
        last_t = e[:timestamp]
        f.write_vlq ts
        f.write_byte 0xE0 + cc
        f.write_byte pitch_int & 0x7F
        f.write_byte (pitch_int >> 7) & 0x7F
      end
    end
    f.write_vlq 0
    f.write_byte 0xFF
    f.write_byte 0x2F
    f.write_byte 0x00
    len = f.tell - s
    f.seek p
    f.write_u32_be len
  end

end

puts "Finished"
