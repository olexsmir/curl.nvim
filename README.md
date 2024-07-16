<div align="center">
<img src="https://github.com/oysandvik94/curl.nvim/assets/25078429/65ad4dd4-cb7a-4ef9-a503-ff6693129efb" data-canonical-src="https://github.com/oysandvik94/curl.nvim/assets/25078429/65ad4dd4-cb7a-4ef9-a503-ff6693129efb" width="300" height="300" />
  
# curl.nvim
  
💪 Integrate curl and jq in Neovim. 💪

</div>

https://github.com/oysandvik94/curl.nvim/assets/25078429/9c25d289-c293-41c4-9d8d-40a0e8b013ed

curl.nvim allows you to run HTTP requests with curl from a scratchpad, and display the formatted output

- Introduces the ".curl" filetype, where pressing enter will execute a curl request under the cursor
- Quality of life formatting features, so that writing out curl commands is a *little* less tedious
- Output is formatted using JQ
- Open a curl command buffer that is either persisted globally or per working directory
- Store collections (named files) that are etiher persisted globally or per working directory
- It's just curl, so all the headers and auth flags you already know works

See [the features section](<README#✨ Features>) for more information.

The plugin aims to be 100% compatible with curl; if a curl command can execute in your shell,
you will be able to paste it in to the scratch buffer and run it.
Because of this, the plugin attempts to get the balance of being ergonomic and convenient, while
still using the knowledge of curl you already have.

## Installation and requirements

- [Curl](https://curl.se)
- [jq](https://jqlang.github.io/jq/),
- Linux/Mac (I dont have a windows machine to test, feel free to create a PR)

Installation example for [Lazy](https://github.com/folke/lazy.nvim):

```lua
{
  "oysandvik94/curl.nvim",
  cmd = { "CurlOpen" },
  dependencies = {
  "nvim-lua/plenary.nvim",
},
config = true,
}
```

Below follows some example keymaps, but you should find a setup that works for you:

```lua
local curl = require("curl")
curl.setup({})

vim.keymap.set("n", "<leader>cc", function()
    curl.open_curl_tab()
end, { desc = "Open a curl tab scoped to the current working directory" })

vim.keymap.set("n", "<leader>co", function()
    curl.open_global_tab()
end, { desc = "Open a curl tab with gloabl scope" })

vim.keymap.set("n", "<leader>csc", function()
    vim.ui.input({ prompt = "Collection name: " }, function(input)
        curl.open_scoped_collection(input)
    end)
end, { desc = "Create or open a collection with a name from user input" })

vim.keymap.set("n", "<leader>cgc", function()
    vim.ui.input({ prompt = "Collection name: " }, function(input)
        curl.open_global_collection(input)
    end)
end, { desc = "Create or open a global collection with a name from user input" })
```

To verify the installation run `:checkhealth curl`.

## Configuration

You can configure curl.nvim by running the `curl.setup()` function, passing a table as the argument.

Or if you use [Lazy](https://github.com/folke/lazy.nvim), just pass the table into `opts` as described [here](https://lazy.folke.io/spec#spec-setup).

<details>
<summary>Default Config</summary>

```lua
{
  -- Table of strings to specify default headers to be included in each request, i.e. "-i"
  default_flags = { },
  mappings = {
      execute_curl = "<CR>"
  }
}
```

</details>

## Usage

You can open curl.nvim in four ways:

```vim
" A buffer that is scoped to the current working directory
:CurlOpen

" A global buffer that will be the same for all Neovim instances
:CurlOpen global

" A buffer with a custom name that can be opened from any Neovim instance
:CurlOpen collection global {any_name}

" A buffer with a custom name that is scoped to the curren working directory
:CurlOpen collection scoped {any_name}
```

or using the lua api:

```lua
require("curl").open_curl_tab()
require("curl").open_global_tab()
require("curl").open_global_collection("my_curls")
require("curl").open_scoped_collection("my_curls")
```

Any of these commands will open a new tab containing two buffers split vertically.

In the left buffer, you can paste or write curl commands, and by pressing Enter, the
command will execute, and the output will be shown and formatted in the rightmost buffer.

If you wish, you can select the text in the right buffer, and filter it using jq, i.e.
`ggVG! jq '{query goes here}'`

See examples under [Features](<README#✨ Features>) for more information

## ✨ Features

### 💪 .curl filetype

Opening any file with the ".curl" file extension will activate this plugins features. 
You will get some syntax highlighting and the ability to execute curl commands from you buffer.
Since any ".curl" file will work, you can manage your own collection instead of using the builtin
system, and even check in files to your repository.

### 💪 Formatting

#### No quotes needed

JSON bodies do not have to be wrapped in quotes, making it easier to format JSON with JQ (va{:!jq)

<details>
<summary>See example</summary>

```bash
curl -X POST https://jsonplaceholder.typicode.com/posts
-H 'Content-Type: application/json'
-d
{
  "title": "now try this"
}
```

</details>

#### No trailing \\

You dont need a trailing \\, but it wont matter if they are there, making it easier to copy-paste requests

<details>
<summary>See example</summary>

```bash
curl -X POST https://jsonplaceholder.typicode.com/posts \
-H 'Content-Type: application/json' \
-d '{"title": "now try this"}'
```

</details>

#### Comment out lines

Headers and/or parts of the body can be commented out using '#', making ad-hoc experimenting with
requests easier

<details>
<summary>See example</summary>

```bash
curl -X POST https://jsonplaceholder.typicode.com/posts
-H 'Content-Type: application/json'
-d
{
  # "title": "remember me"
  "title": "now try this"
}
```

</details>

### 💪 Headers

Basic auth and bearer tokens work, and can be retrieved from environment variables

> [!CAUTION]  
> The command scratch buffer is stored in plaintext in your Neovim data directory, be careful when using literal secrets!

<details>
<summary>See example</summary>

```bash
curl -u "username:password" http://httpbin.org/basic-auth/username/password

curl -u "username:$PASSWORD_TEST" http://httpbin.org/basic-auth/username/mypassword

curl -X GET "https://httpbin.org/bearer" -H "accept: application/json" -H "Authorization: Bearer myrandomtoken"

curl -X GET "https://httpbin.org/bearer" -H "accept: application/json" -H "Authorization: Bearer $TOKEN_TEST"
```

</details>

### 💪 Persistence

There are multiple ways to work with the scratch buffers, so you can tailor it to your own workflow.

#### Per directory

Running `:CurlOpen` or `require("curl").open_curl_tab()` will open a command buffer that is
tied to your current working directory. If you open neovim in a different directory, a different
set of commands will be shown.

If you treat directories as "projects", and always open neovim in the root of your project directories,
then this option might be useful for you.

#### Global buffers

If you want your curl commands to always be available, regardless of where you launch Neovim from,
use the global option.

```vim
:CurlOpen global
```

```lua
require("curl").open_global_tab()
```

#### Collections

If you want more control, or would like to organize your curl commands in logical collections,
you can use the "collection" option to give names to your collections.

This will create a new collection, or open a collection if it exists with the given name

You can either open a global collection, which is accessible from any Neovim instance,
or a scoped collection which belongs to the current working directory. This means that if you
have two collections with the same name created from different directories, the correct one
will open from the given directory

```vim
:CurlOpen collection global mycoolcurls
:CurlOpen collection scoped mycoolcurls
```

```lua
require("curl").open_global_collection("mycoolcurls")
require("curl").open_scoped_collection("mycoolcurls")
```

## Lua api

The plugin also exposes this lua api:

<details>
<summary>See lua api</summary>

```lua
local curl = require('curl')

-- See ### Persistence under ## Features
curl.open_curl_tab()
curl.open_global_tab()
curl.open_scoped_collection()
curl.open_global_collection()

-- Close the tab containing curl buffers
curl.close_curl_tab()

-- Executes the curl command under the cursor when the command buffer is open
-- Also executed by the "execute_curl" mapping, as seen in the configuration. Mapped to <CR> by default
curl.execute_curl()
```

</details>

## Future plans

Interesting features that might arrive soon:

- Format JSON under the cursor in the scratch window with a single keybind
- Be able to do simple jq queries in the output window. For example: while the cursor is
  on a key in the json, execute a keybind to filter the entire json for that key
- Enhance organization, by maybe folds, creating a picker for commands in the scratch,
  or multiple named scratches

## Similar plugins

- [kulala.nvim](https://github.com/mistweaverco/kulala.nvim) using HTTP file syntax instead.
  This is similar to Jetbrains HTTP client and vscode rest-client.
- [rest.nvim](https://github.com/rest-nvim/rest.nvim) using HTTP file syntax instead.
  This is similar to Jetbrains HTTP client and vscode rest-client.

## Contributing

Would you like to contribute? Noice, read [CONTRIBUTING.md](CONTRIBUTING.md)!
