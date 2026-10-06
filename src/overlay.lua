local ouro = require("ouro")
local f = ouro.tokens.foundation

-- Shared look of full-screen shell overlays (launcher, notification center):
-- a blurred, dimmed backdrop and a soft drop shadow behind the card.
local M = {}
local blur = 12
-- How far the shadow spreads past the card's edges, and how far it drops.
M.shadow_reach, M.shadow_offset = 2 * blur, f.spacing_2

function M.background()
  -- The opaque card carries contrast; keep the blurred backdrop light-touch
  -- and dark-tinted even when the content uses the light palette.
  return ouro.color.with_alpha(ouro.tokens.dark.background, 0.3)
end

-- Ourokit has no box-shadow primitive. Return a decorative SVG of
-- `width` x `height` with a blurred rectangle where the card sits at
-- (x, y), dropped by `shadow_offset`. Size the image to cover the card and
-- its reach, clipped to the viewport, and position it behind the card.
function M.shadow(width, height, x, y, card_width, card_height, radius)
  return string.format([[<svg xmlns="http://www.w3.org/2000/svg" width="%g" height="%g">
    <defs><filter id="shadow" x="-50%%" y="-50%%" width="200%%" height="200%%">
      <feGaussianBlur stdDeviation="%g"/>
    </filter></defs>
    <rect x="%g" y="%g" width="%g" height="%g" rx="%g" fill="black" fill-opacity="0.4" filter="url(#shadow)"/>
  </svg>]], width, height, blur, x, y + M.shadow_offset, card_width, card_height, radius)
end

return M
