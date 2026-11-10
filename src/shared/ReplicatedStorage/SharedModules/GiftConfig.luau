return {
	-- Keys are dedicated GIFT developer-product IDs, distinct from direct-buy IDs.
	-- Attributes must be persistent boolean flags (DefaultAttributes or Owned_*).
	-- [1234567890] = { Name = "VIP", Attribute = "Owned_VIP" },
	-- Shop sections register their own shared-ID products; passes use Passes[].GiftID.
}
