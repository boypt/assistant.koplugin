local Device = require("device")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local _ = require("gettext")

local showChatGPTDialog = require("dialogs")
-- local UpdateChecker = require("update_checker")

local Assistant = InputContainer:new {
  name = "Assistant",
  is_doc_only = true,
}

-- Load Configuration
local CONFIGURATION = nil
local success, result = pcall(function() return require("configuration") end)
if success then
  CONFIGURATION = result
else
  print("configuration.lua not found, skipping...")
end

-- Flag to ensure the update message is shown only once per session
local updateMessageShown = false

function Assistant:init()
  -- Assistant button
  self.ui.highlight:addToHighlightDialog("assistant", function(_reader_highlight_instance)
    return {
      text = _("Assistant"),
      enabled = Device:hasClipboard(),
      callback = function()
        if not CONFIGURATION then
          local UIManager = require("ui/uimanager")
          local InfoMessage = require("ui/widget/infomessage")
          UIManager:show(InfoMessage:new{
            text = _("Configuration not found. Please set up configuration.lua first.")
          })
          return
        end
        NetworkMgr:runWhenOnline(function()
          if not updateMessageShown then
            -- UpdateChecker.checkForUpdates()
            updateMessageShown = true
          end
          showChatGPTDialog(self.ui, _reader_highlight_instance.selected_text.text)
        end)
      end,
    }
  end)
  -- Dictionary button
  if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.dictionary_translate_to and CONFIGURATION.features.show_dictionary_button_in_main_popup then
    self.ui.highlight:addToHighlightDialog("dictionary", function(_reader_highlight_instance)
      return {
          text = _("Dictionary").." (AI)",
          enabled = Device:hasClipboard(),
          callback = function()
              NetworkMgr:runWhenOnline(function()
                  local showDictionaryDialog = require("dictdialog")
                  showDictionaryDialog(self.ui, _reader_highlight_instance.selected_text.text)
              end)
          end,
      }
    end)
  end
  
  -- Recap Feature
  if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.enable_AI_recap then
    local ReaderUI    = require("apps/reader/readerui")
    local ConfirmBox  = require("ui/widget/confirmbox")
    local UIManager   = require("ui/uimanager")
    local T 		      = require("ffi/util").template
    local lfs         = require("libs/libkoreader-lfs")   -- for file attributes
    local DocSettings = require("docsettings")			      -- for document progress
  
    -- Save a reference to the original doShowReader method.
    local original_doShowReader = ReaderUI.doShowReader
  
    -- Override the ReaderUI:doShowReader method.
    function ReaderUI:doShowReader(file, provider, seamless)
      -- Get file metadata; here we use the file's "access" attribute.
      local attr = lfs.attributes(file)
      local lastAccess = attr and attr.access or nil
  
      if lastAccess and lastAccess > 0 then -- Has been opened
        local doc_settings = DocSettings:open(file)
        local percent_finished = doc_settings:readSetting("percent_finished")
        local timeDiffHours = (os.time() - lastAccess) / 3600.0
  
        if timeDiffHours >= 28 and percent_finished <= 0.95 then -- More than 28hrs since last open and less than 95% complete
          -- Construct the message to display.
          local doc_props = doc_settings:child("doc_props")
          local title = doc_props:readSetting("title", "Unknown Title")
          local authors = doc_props:readSetting("authors", "Unknown Author")
          local message = string.format(_("Do you want an AI Recap?\nFor %s by %s.\nLast read %.0f hours ago."), title, authors, timeDiffHours) -- can add in percent_finished too
  
          -- Display the request popup using ConfirmBox.
          UIManager:show(ConfirmBox:new{
            text            = T(_(message)),
            ok_text         = _("Yes"),
            ok_callback     = function()
              NetworkMgr:runWhenOnline(function()
                local showRecapDialog = require("recapdialog")
                showRecapDialog(self.ui, title, authors, percent_finished)
              end)
            end,
            cancel_text     = _("No"),
          })
        end
      end
      original_doShowReader(self, file, provider, seamless)
    end
  end

  -- Add Custom buttons (ones with show_on_main_popup = true)
  if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.prompts then
    local _ = require("gettext")  -- Ensure gettext is available in this scope
    -- Create a sorted list of prompts
    local sorted_prompts = {}
    for prompt_type, prompt in pairs(CONFIGURATION.features.prompts) do
      if prompt.show_on_main_popup then
        table.insert(sorted_prompts, {type = prompt_type, config = prompt})
      end
    end
    
    -- Sort by order value, default to 1000 if not specified
    table.sort(sorted_prompts, function(a, b)
      local order_a = a.config.order or 1000
      local order_b = b.config.order or 1000
      return order_a < order_b
    end)
    
    -- Add buttons in sorted order
    for _, prompt_data in ipairs(sorted_prompts) do
      local prompt_type = prompt_data.type
      local prompt = prompt_data.config
      -- Use order in the index for proper sorting (pad with zeros for consistent sorting)
      local order_str = string.format("%02d", prompt.order or 1000)
      self.ui.highlight:addToHighlightDialog("assistant_" .. order_str .. "_" .. prompt_type, function(_reader_highlight_instance)
        return {
          text = prompt.text.." (AI)", 
          enabled = Device:hasClipboard(),
          callback = function()
            NetworkMgr:runWhenOnline(function()
              showChatGPTDialog(self.ui, _reader_highlight_instance.selected_text.text, prompt_type)
            end)
          end,
        }
      end)
    end
  end
end

function Assistant:onDictButtonsReady(dict_popup, buttons)
  if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.show_dictionary_button_in_dictionary_popup then
    table.insert(buttons, 1, {{
        id = "assistant_dictionary",
        text = _("Dictionary").." (AI)",
        font_bold = false,
        callback = function()
            NetworkMgr:runWhenOnline(function()
                local showDictionaryDialog = require("dictdialog")
                -- Pass the word from the dict_popup instead of the highlight instance:
                showDictionaryDialog(self.ui, dict_popup.lookupword)
            end)
        end,
    }})
  end
end

return Assistant
