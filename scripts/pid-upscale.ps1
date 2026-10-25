{
    "description":  "分离人声/伴奏 → 人声降噪 → 转字幕 → 转 MIDI。参数：Audio（必填）",
    "name":  "音频处理链",
    "vars":  {
                 "Language":  "zh",
                 "Audio":  ""
             },
    "steps":  [
                  {
                      "params":  {
                                     "Audio":  "{{Audio}}"
                                 },
                      "id":  "split",
                      "tool":  "audio-split"
                  },
                  {
                      "params":  {
                                     "Audio":  "{{Audio}}"
                                 },
                      "id":  "denoise",
                      "tool":  "audio-denoise"
                  },
                  {
                      "params":  {
                                     "Audio":  "{{out.denoise}}",
                                     "Language":  "{{Language}}",
                                     "Formats":  "srt,txt"
                                 },
                      "id":  "subtitle",
                      "tool":  "audio-subtitle"
                  },
                  {
                      "params":  {
                                     "Audio":  "{{Audio}}"
                                 },
                      "id":  "midi",
                      "tool":  "audio-midi"
                  }
              ]
}