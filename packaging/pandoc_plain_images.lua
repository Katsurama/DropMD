local inline_images = os.getenv("DROPMD_INLINE_IMAGES") == "1"
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function digit(n)
  return alphabet:sub(n + 1, n + 1)
end

local function base64(bytes)
  local encoded = bytes:gsub("(.)(.?)(.?)", function (a, b, c)
    local x, y, z = a:byte(), b:byte() or 0, c:byte() or 0
    return digit(x >> 2) .. digit(((x & 3) << 4) | (y >> 4))
      .. (#b > 0 and digit(((y & 15) << 2) | (z >> 6)) or "=")
      .. (#c > 0 and digit(z & 63) or "=")
  end)
  return encoded
end

-- 去掉图片的宽高等属性，使 Pandoc 输出标准的 ![](路径) 语法，而不是 <img> 标签
function Image(el)
  el.attributes = {}
  if inline_images then
    -- 只读 Word 本身已提供的图片，不读取链接指向的文件或网络资源。
    local mime, bytes = pandoc.mediabag.lookup(el.src)
    if mime and bytes then
      el.src = "data:" .. mime .. ";base64," .. base64(bytes)
    end
  end
  return el
end
