-- 去掉图片的宽高等属性，使 Pandoc 输出标准的 ![](路径) 语法，而不是 <img> 标签
function Image(el)
  el.attributes = {}
  return el
end
