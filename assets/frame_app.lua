local data = require('data.min')
local battery = require('battery.min')
local sprite = require('sprite.min')
local code = require('code.min')
local text_sprite_block = require('text_sprite_block.min')

-- Phone to Frame flags
TEXT_SPRITE_BLOCK = 0x20
CLEAR_MSG = 0x10

-- Register the message parsers so they are automatically called when matching data comes in
data.parsers[TEXT_SPRITE_BLOCK] = text_sprite_block.parse_text_sprite_block
data.parsers[CLEAR_MSG] = code.parse_code

-- Main app loop
function app_loop()
  -- Clear the display
  frame.display.text(" ", 1, 1)
  frame.display.show()
  local last_batt_update = 0

  while true do
    -- Process any raw data items, if ready
    local items_ready = data.process_raw_items()

    -- One or more full messages received
    if items_ready > 0 then

      if (data.app_data[TEXT_SPRITE_BLOCK] ~= nil) then
        -- Show the text sprite block
        local tsb = data.app_data[TEXT_SPRITE_BLOCK]
        print("Received TEXT_SPRITE_BLOCK with " .. #tsb.sprites .. " sprites.")

        for index, spr in ipairs(tsb.sprites) do
          print("Processing Sprite " .. index .. ": width=" .. spr.width .. ", bpp=" .. spr.bpp)
          frame.display.bitmap(1, tsb.offsets[index].y + 1, spr.width, 2^spr.bpp, 0 + index, spr.pixel_data)
        end
        frame.display.show()

        -- Nil out the TEXT_SPRITE_BLOCK after processing
        data.app_data[TEXT_SPRITE_BLOCK] = nil
      end

      if (data.app_data[CLEAR_MSG] ~= nil) then
        -- Clear the display
        frame.display.text(" ", 1, 1)
        frame.display.show()

        data.app_data[CLEAR_MSG] = nil
      end
    end

    -- Periodic battery level updates, 120s for a camera app
    last_batt_update = battery.send_batt_if_elapsed(last_batt_update, 120)
    frame.sleep(0.1)
  end
end

-- Run the main app loop
app_loop()
