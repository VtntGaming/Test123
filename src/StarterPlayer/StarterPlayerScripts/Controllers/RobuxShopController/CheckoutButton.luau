--!strict
-- Shows immediate feedback for one managed checkout and restores its button on a correlated response.

--// Constants
local LOADING_TIMEOUT_SECONDS = 60

--// Properties
local PendingRequest: Pending? = nil

--// Types
type Pending = {
	RequestId: string,
	Button: GuiButton,
	Price: TextLabel,
	Text: string,
	Active: boolean,
	Interactable: boolean,
	Selectable: boolean,
	AutoButtonColor: boolean,
	Timeout: thread?,
	Destroyed: RBXScriptConnection?,
}

export type CheckoutButton = {
	Begin: (button: GuiButton, price: TextLabel, requestId: string, onTimeout: () -> ()) -> boolean,
	Finish: (requestId: string) -> (),
	SetPrice: (price: TextLabel, text: string) -> (),
	SetState: (button: GuiButton, enabled: boolean, claimed: boolean, category: string?) -> (),
}

--// Module
local CheckoutButton = {} :: CheckoutButton

--// APIs
function CheckoutButton.Finish(requestId)
	local pending = PendingRequest
	if not pending or pending.RequestId ~= requestId then
		return
	end
	PendingRequest = nil
	if pending.Timeout then
		task.cancel(pending.Timeout)
	end
	if pending.Destroyed then
		pending.Destroyed:Disconnect()
	end
	if pending.Button.Parent then
		pending.Button.Active = pending.Active
		pending.Button.Interactable = pending.Interactable
		pending.Button.Selectable = pending.Selectable
		pending.Button.AutoButtonColor = pending.AutoButtonColor
	end
	if pending.Price.Parent then
		pending.Price.Text = pending.Text
	end
end

function CheckoutButton.Begin(button, price, requestId, onTimeout)
	if PendingRequest then
		return false
	end
	local pending: Pending = {
		RequestId = requestId,
		Button = button,
		Price = price,
		Text = price.Text,
		Active = button.Active,
		Interactable = button.Interactable,
		Selectable = button.Selectable,
		AutoButtonColor = button.AutoButtonColor,
	}
	PendingRequest = pending
	button.Active = false
	button.Interactable = false
	button.Selectable = false
	button.AutoButtonColor = false
	price.Text = "Opening..."
	pending.Destroyed = button.Destroying:Once(function()
		CheckoutButton.Finish(requestId)
	end)
	pending.Timeout = task.delay(LOADING_TIMEOUT_SECONDS, function()
		if PendingRequest ~= pending then
			return
		end
		-- This watchdog only restores presentation; it never cancels a saved checkout.
		pending.Timeout = nil
		CheckoutButton.Finish(requestId)
		onTimeout()
	end)
	return true
end

function CheckoutButton.SetState(button, enabled, claimed, category)
	local pending = PendingRequest
	local loading = pending ~= nil and pending.Button == button
	if pending and pending.Button == button then
		-- Completion must restore the latest ownership state, not its pre-purchase value.
		pending.Active = enabled
		pending.Interactable = enabled
		pending.Selectable = enabled
		pending.AutoButtonColor = enabled
	end
	button.Active = enabled and not loading
	button.Interactable = enabled and not loading
	button.Selectable = enabled and not loading
	button.AutoButtonColor = enabled and not loading
	local hover = button:FindFirstChild("hover")
	if hover and hover:IsA("Frame") then
		--hover.Visible = claimed
		hover.Visible = false
	end
	local priceText = button:FindFirstChild("Price")
	if priceText and priceText:IsA("TextLabel") and claimed then
		priceText.Text = if category and (category == "Passes" or category == "Exclusive") then "OWNED" else "CLAIMED"
	end
end

function CheckoutButton.SetPrice(price, text)
	local pending = PendingRequest
	if pending and pending.Price == price then
		-- A product-info request may finish while the button is loading.
		pending.Text = text
	else
		price.Text = text
	end
end

return CheckoutButton
