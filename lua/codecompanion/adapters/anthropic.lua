local log = require("codecompanion.utils.log")
local tokens = require("codecompanion.utils.tokens")
local utils = require("codecompanion.utils.messages")

local input_tokens = 0
local output_tokens = 0

---@class CodeCompanion.AdapterArgs
return {
  name = "anthropic",
  roles = {
    llm = "assistant",
    user = "user",
  },
  features = {
    tokens = true,
    text = true,
    vision = true,
  },
  url = "https://api.anthropic.com/v1/messages",
  env = {
    api_key = "ANTHROPIC_API_KEY",
  },
  headers = {
    ["content-type"] = "application/json",
    ["x-api-key"] = "${api_key}",
    ["anthropic-version"] = "2023-06-01",
    ["anthropic-beta"] = "prompt-caching-2024-07-31",
  },
  parameters = {
    stream = true,
  },
  opts = {
    cache_over = 300, -- Cache any message which has this many tokens or more
  },
  handlers = {
    ---Set the parameters
    ---@param self CodeCompanion.Adapter
    ---@param params table
    ---@param messages table
    ---@return table
    form_parameters = function(self, params, messages)
      return params
    end,

    ---Set the format of the role and content for the messages from the chat buffer
    ---@param self CodeCompanion.Adapter
    ---@param messages table Format is: { { role = "user", content = "Your prompt here" } }
    ---@return table
    form_messages = function(self, messages)
      -- Put system prompts into their own table...
      local system = {}
      for _, prompt in ipairs(utils.pluck_messages(messages, "system")) do
        table.insert(system, {
          type = "text",
          text = prompt.content,
          -- Cache system prompts
          cache_control = { type = "ephemeral" },
        })
      end
      if next(system) == nil then
        system = nil
      end

      -- ...ensuring that they're removed from the messages table
      utils.pop_messages(messages, "system")
      -- And ensuring that consecutive messages of the same role are merged
      messages = utils.merge_messages(messages)

      -- As per: https://github.com/anthropics/anthropic-cookbook/blob/main/misc/prompt_caching.ipynb
      -- Claude now supports caching. We cache any message that exceeds the opts.cache_over number
      for _, message in ipairs(messages) do
        if message.role == self.args.roles.user and tokens.calculate(message.content) >= self.args.opts.cache_over then
          message.content = {
            {
              type = "text",
              text = message.content,
              cache_control = { type = "ephemeral" },
            },
          }
        end
      end

      return { system = system, messages = messages }
    end,

    ---Returns the number of tokens generated from the LLM
    ---@param data string The data from the LLM
    ---@return number|nil
    tokens = function(data)
      if data then
        data = data:sub(6)
        local ok, json = pcall(vim.fn.json_decode, data)

        if ok then
          if json.type == "message_start" then
            input_tokens = json.message.usage.input_tokens or 0
            output_tokens = json.message.usage.output_tokens or 0
          end
          if json.type == "message_delta" then
            return (input_tokens + output_tokens + json.usage.output_tokens)
          end
        end
      end
    end,

    ---Output the data from the API ready for insertion into the chat buffer
    ---@param data string The streamed JSON data from the API, also formatted by the format_data handler
    ---@return table|nil
    chat_output = function(data)
      local output = {}

      -- Skip the event messages
      if type(data) == "string" and string.sub(data, 1, 6) == "event:" then
        return
      end

      if data and data ~= "" then
        data = data:sub(6)
        local ok, json = pcall(vim.json.decode, data, { luanil = { object = true } })

        if ok then
          if json.type == "message_start" then
            output.role = json.message.role
            output.content = ""
          elseif json.type == "content_block_delta" then
            output.role = nil
            output.content = json.delta.text
          end

          return {
            status = "success",
            output = output,
          }
        end
      end
    end,

    ---Output the data from the API ready for inlining into the current buffer
    ---@param data table The streamed JSON data from the API, also formatted by the format_data handler
    ---@param context table Useful context about the buffer to inline to
    ---@return table|nil
    inline_output = function(data, context)
      if type(data) == "string" and string.sub(data, 1, 6) == "event:" then
        return
      end

      if data and data ~= "" then
        data = data:sub(6)
        local ok, json = pcall(vim.json.decode, data, { luanil = { object = true } })

        if ok then
          if json.type == "content_block_delta" then
            return json.delta.text
          end
        end
      end
    end,

    ---Function to catch any errors from the standard output
    ---@param self CodeCompanion.Adapter
    ---@param data table
    ---@return nil
    on_stdout = function(self, data)
      local ok, json = pcall(vim.json.decode, data._stdout_results[1], { luanil = { object = true } })
      if ok then
        log:trace("stdout: %s", json)
        if json.error then
          log:error("Error: %s", json.error.message)
        end
      end
    end,
  },
  schema = {
    model = {
      order = 1,
      mapping = "parameters",
      type = "enum",
      desc = "The model that will complete your prompt. See https://docs.anthropic.com/claude/docs/models-overview for additional details and options.",
      default = "claude-3-5-sonnet-20240620",
      choices = {
        "claude-3-5-sonnet-20240620",
        "claude-3-opus-20240229",
        "claude-3-haiku-20240307",
        "claude-2.1",
      },
    },
    max_tokens = {
      order = 2,
      mapping = "parameters",
      type = "number",
      optional = true,
      default = 4096,
      desc = "The maximum number of tokens to generate before stopping. This parameter only specifies the absolute maximum number of tokens to generate. Different models have different maximum values for this parameter.",
      validate = function(n)
        return n > 0 and n <= 8192, "Must be between 0 and 8192"
      end,
    },
    temperature = {
      order = 3,
      mapping = "parameters",
      type = "number",
      optional = true,
      default = 0,
      desc = "Amount of randomness injected into the response. Ranges from 0.0 to 1.0. Use temperature closer to 0.0 for analytical / multiple choice, and closer to 1.0 for creative and generative tasks. Note that even with temperature of 0.0, the results will not be fully deterministic.",
      validate = function(n)
        return n >= 0 and n <= 1, "Must be between 0 and 1.0"
      end,
    },
    top_p = {
      order = 4,
      mapping = "parameters",
      type = "number",
      optional = true,
      default = nil,
      desc = "Computes the cumulative distribution over all the options for each subsequent token in decreasing probability order and cuts it off once it reaches a particular probability specified by top_p",
      validate = function(n)
        return n >= 0 and n <= 1, "Must be between 0 and 1"
      end,
    },
    top_k = {
      order = 5,
      mapping = "parameters",
      type = "number",
      optional = true,
      default = nil,
      desc = "Only sample from the top K options for each subsequent token. Use top_k to remove long tail low probability responses",
      validate = function(n)
        return n >= 0 and n <= 500, "Must be between 0 and 500"
      end,
    },
    stop_sequences = {
      order = 6,
      mapping = "parameters",
      type = "list",
      optional = true,
      default = nil,
      subtype = {
        type = "string",
      },
      desc = "Sequences where the API will stop generating further tokens",
      validate = function(l)
        return #l >= 1, "Must have more than 1 element"
      end,
    },
  },
}
