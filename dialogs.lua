local InputDialog = require("ui/widget/inputdialog")
local ChatGPTViewer = require("chatgptviewer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local _ = require("gettext")

local queryChatGPT = require("gpt_query")

local CONFIGURATION = nil
local buttons, input_dialog = nil, nil

local success, result = pcall(function() return require("configuration") end)
if success then
  CONFIGURATION = result
else
  print("configuration.lua not found, skipping...")
end

-- Common helper functions
local function showLoadingDialog()
  local loading = InfoMessage:new{
    text = _("Loading..."),
    timeout = 0.1
  }
  UIManager:show(loading)
end

-- Helper function to truncate text based on configuration
local function truncateUserPrompt(text)
  if not CONFIGURATION or not CONFIGURATION.features.max_display_user_prompt_length then
    return text
  end
  
  local max_length = CONFIGURATION.features.max_display_user_prompt_length
  if max_length <= 0 then
    return text
  end
  
  if text and #text > max_length then
    return text:sub(1, max_length) .. "..."
  end
  return text
end

local function getBookContext(ui)
  return {
    title = ui.document:getProps().title or _("Unknown Title"),
    author = ui.document:getProps().authors or _("Unknown Author")
  }
end

local function formatUserPrompt(user_prompt, highlightedText, ui)
  local book = getBookContext(ui)
  local formatted_user_prompt = (user_prompt or "Please analyze: ")
    :gsub("{title}", book.title)
    :gsub("{author}", book.author)
    :gsub("{highlight}", highlightedText)
  
  local formatted_user_content = ""
  if string.find(user_prompt or "Please analyze: ", "{highlight}") then
    formatted_user_content = formatted_user_prompt
  else
    formatted_user_content = formatted_user_prompt .. highlightedText
  end

  return formatted_user_content
end

local function createContextMessage(ui, highlightedText)
  local book = getBookContext(ui)
  return {
    role = "user",
    content = "I'm reading something titled '" .. book.title .. "' by " .. book.author ..
      ". I have a question about the following highlighted text: " .. highlightedText,
    is_context = true
  }
end

local function handleFollowUpQuestion(message_history, new_question, ui, highlightedText)
  local context_message = createContextMessage(ui, highlightedText)
  table.insert(message_history, context_message)

  local question_message = {
    role = "user",
    content = formatUserPrompt(new_question, highlightedText, ui)
  }
  table.insert(message_history, question_message)

  local answer = queryChatGPT(message_history)
  local answer_message = {
    role = "assistant",
    content = answer
  }
  table.insert(message_history, answer_message)

  return message_history
end

local function createResultText(highlightedText, message_history, previous_text, show_highlighted_text)
  if not previous_text then
    local result_text = ""
    -- Check if we should show highlighted text based on configuration
    if show_highlighted_text and 
       (not CONFIGURATION or 
        not CONFIGURATION.features or 
        not CONFIGURATION.features.hide_highlighted_text) then
      
      -- Check for long text
      local should_show = true
      if CONFIGURATION and CONFIGURATION.features then
        if CONFIGURATION.features.hide_long_highlights and 
           CONFIGURATION.features.long_highlight_threshold and 
           #highlightedText > CONFIGURATION.features.long_highlight_threshold then
          should_show = false
        end
      end
      
      if should_show then
        result_text = _("__Highlighted text: __") .. "\"" .. highlightedText .. "\"\n\n"
      end
    end
    
    for i = 2, #message_history do
      if not message_history[i].is_context then
        if message_history[i].role == "user" then
          result_text = result_text .. "### ⮞ " .. _("User: ") .. "\n\n" .. truncateUserPrompt(message_history[i].content) .. "\n"
        else
          result_text = result_text .. "### ⮞ Assistant: \n\n" .. message_history[i].content .. "\n"
        end
      end
    end
    return result_text
  end

  local last_user_message = message_history[#message_history - 1]
  local last_assistant_message = message_history[#message_history]

  if last_user_message and last_user_message.role == "user" and 
     last_assistant_message and last_assistant_message.role == "assistant" then
    -- Add nil checks for content
    local user_content = last_user_message.content or _("(Empty message)")
    local assistant_content = last_assistant_message.content or _("(No response)")
    return previous_text .. 
           "### ⮞ " .. _("User: ") .. "\n" .. truncateUserPrompt(user_content) .. "\n" .. 
           "### ⮞ Assistant: \n" .. assistant_content .. "\n"
  end

  return previous_text
end

-- Helper function to create and show ChatGPT viewer
local function createAndShowViewer(ui, highlightedText, message_history, title, show_highlighted_text)
  show_highlighted_text = show_highlighted_text == nil and true or show_highlighted_text
  local result_text = createResultText(highlightedText, message_history, nil, show_highlighted_text)
  local render_markdown = (CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.render_markdown) or true
  local markdown_font_size = (CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.markdown_font_size) or 20
  
  local chatgpt_viewer = ChatGPTViewer:new {
    title = _(title),
    text = result_text,
    ui = ui,
    onAskQuestion = function(viewer, new_question)
      NetworkMgr:runWhenOnline(function()
        -- Use viewer's own highlighted_text value
        local current_highlight = viewer.highlighted_text or highlightedText
        message_history = handleFollowUpQuestion(message_history, new_question, ui, current_highlight)
        local new_result_text = createResultText(current_highlight, message_history, viewer.text, false)
        viewer:update(new_result_text)
        
        if viewer.scroll_text_w then
          viewer.scroll_text_w:resetScroll()
        end
      end)
    end,
    highlighted_text = highlightedText,
    message_history = message_history,
    render_markdown = render_markdown,
    markdown_font_size = markdown_font_size,
  }
  
  UIManager:show(chatgpt_viewer)
  
  -- Refresh the screen after displaying the results
  if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.refresh_screen_after_displaying_results then
    UIManager:setDirty(nil, "full")
  end
end

-- Handle predefined prompt request
local function handlePredefinedPrompt(prompt_type, highlightedText, ui)
  if not CONFIGURATION or not CONFIGURATION.features or not CONFIGURATION.features.prompts then
    return nil, "No prompts configured"
  end

  local prompt = CONFIGURATION.features.prompts[prompt_type]
  if not prompt then
    return nil, "Prompt '" .. prompt_type .. "' not found"
  end

  local user_content = formatUserPrompt(prompt.user_prompt, highlightedText, ui)
  local message_history = {
    {
      role = "system",
      content = prompt.system_prompt or "You are a helpful assistant."
    },
    {
      role = "user",
      content = user_content,
      is_context = true
    }
  }
  
  local answer = queryChatGPT(message_history)
  if answer then
    table.insert(message_history, {
      role = "assistant",
      content = answer
    })
  end
  
  return message_history, nil
end

-- Main dialog function
local function showChatGPTDialog(ui, highlightedText, direct_prompt)
  if input_dialog then
    UIManager:close(input_dialog)
    input_dialog = nil
  end

  -- Handle direct prompts ( custom)
  if direct_prompt then
    showLoadingDialog()
    UIManager:scheduleIn(0.1, function()
      local message_history, err
      local title

      message_history, err = handlePredefinedPrompt(direct_prompt, highlightedText, ui)
      if err then
        UIManager:show(InfoMessage:new{text = _("Error: " .. err)})
        return
      end
      title = CONFIGURATION.features.prompts[direct_prompt].text

      if not message_history or #message_history < 1 then
        UIManager:show(InfoMessage:new{text = _("Error: No response received")})
        return
      end

      createAndShowViewer(ui, highlightedText, message_history, title)
    end)
    return
  end

  -- Handle regular dialog with buttons
  local book = getBookContext(ui)
  local message_history = {{
    role = "system",
    content = CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.system_prompt or "You are a helpful assistant for reading comprehension."
  }}

  -- Create button rows (3 buttons per row)
  local button_rows = {}
  local all_buttons = {
    {
      text = _("Cancel"),
      id = "close",
      callback = function()
        if input_dialog then
          UIManager:close(input_dialog)
          input_dialog = nil
        end
      end
    },
    {
      text = _("Ask"),
      is_enter_default = true,
      callback = function()
        showLoadingDialog()
        UIManager:scheduleIn(0.1, function()
          local context_message = createContextMessage(ui, highlightedText)
          table.insert(message_history, context_message)

          local question_message = {
            role = "user",
            content = input_dialog:getInputText()
          }
          table.insert(message_history, question_message)

          local answer = queryChatGPT(message_history)
          local answer_message = {
            role = "assistant",
            content = answer
          }
          table.insert(message_history, answer_message)

          -- Close input dialog and keyboard before showing the viewer
          if input_dialog then
            UIManager:close(input_dialog)
            input_dialog = nil
          end
          
          createAndShowViewer(ui, highlightedText, message_history, "Assistant")
        end)
      end
    }
  }
  
  -- Add Dictionary button
  if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.dictionary_translate_to then
    table.insert(all_buttons, {
      text = _("Dictionary"),
      callback = function()
        if input_dialog then
          UIManager:close(input_dialog)
          input_dialog = nil
        end
        showLoadingDialog()
        UIManager:scheduleIn(0.1, function()
          local showDictionaryDialog = require("dictdialog")
          showDictionaryDialog(ui, highlightedText)
        end)
      end
    })  
  end


  -- Add custom prompt buttons
  if CONFIGURATION and CONFIGURATION.features and CONFIGURATION.features.prompts then
    -- Create a sorted list of prompts
    local sorted_prompts = {}
    for prompt_type, prompt in pairs(CONFIGURATION.features.prompts) do
      table.insert(sorted_prompts, {type = prompt_type, config = prompt})
    end
    -- Sort by order value, default to 1000 if not specified
    table.sort(sorted_prompts, function(a, b)
      local order_a = a.config.order or 1000
      local order_b = b.config.order or 1000
      return order_a < order_b
    end)
    
    -- Add buttons in sorted order
    for idx, prompt_data in ipairs(sorted_prompts) do
      local prompt_type = prompt_data.type
      local prompt = prompt_data.config
      table.insert(all_buttons, {
        text = _(prompt.text),
        callback = function()
          UIManager:close(input_dialog)
          input_dialog = nil
          showLoadingDialog()
          UIManager:scheduleIn(0.1, function()
            local message_history, err = handlePredefinedPrompt(prompt_type, highlightedText, ui)
            if err then
              UIManager:show(InfoMessage:new{text = _("Error: " .. err)})
              return
            end
            createAndShowViewer(ui, highlightedText, message_history, prompt.text)
          end)
        end
      })
    end
  end
  
  -- Organize buttons into rows of three
  local current_row = {}
  for _, button in ipairs(all_buttons) do
    table.insert(current_row, button)
    if #current_row == 3 then
      table.insert(button_rows, current_row)
      current_row = {}
    end
  end
  
  if #current_row > 0 then
    table.insert(button_rows, current_row)
  end

  -- Show the dialog with the button rows
  input_dialog = InputDialog:new{
    title = _("Ask a question about the highlighted text"),
    input_hint = _("Type your question here..."),
    input_type = "text",
    buttons = button_rows,
    close_callback = function()
      if input_dialog then
        UIManager:close(input_dialog)
        input_dialog = nil
      end
    end,
    dismiss_callback = function()
      if input_dialog then
        UIManager:close(input_dialog)
        input_dialog = nil
      end
    end
  }
  UIManager:show(input_dialog)
  input_dialog:onShowKeyboard()
end

return showChatGPTDialog
