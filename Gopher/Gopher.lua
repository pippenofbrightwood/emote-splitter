-------------------------------------------------------------------------------
-- Gopher
-- by Tammya-MoonGuard (Copyright 2018)
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
--  of  this software and associated documentation files  (the "Software"),  to
--  deal in the Software without restriction,  including without limitation the
--  rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
--  sell copies of the Software,  and to permit persons to whom the Software is
--  furnished to do so, subject to the following conditions:
--
-- The above  copyright  notice  and  this permission notice  shall be included 
--  in all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS",  WITHOUT WARRANTY OF ANY KIND,  EXPRESS OR
--  IMPLIED,  INCLUDING BUT NOT LIMITED TO THE WARRANTIES  OF  MERCHANTABILITY,
--  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
--  AUTHORS  OR  COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,  DAMAGES  OR  OTHER
--  LIABILITY,  WHETHER IN AN ACTION  OF CONTRACT,  TORT OR OTHERWISE,  ARISING
--  FROM,  OUT  OF  OR  IN CONNECTION WITH THE SOFTWARE  OR  THE USE  OR  OTHER
--  DEALINGS IN THE SOFTWARE.
--
-- Here are the key features that this library provides:
--   * Allows SendChatMessage  and  other  similar methods  to  accept messages
--      larger than  255  characters,  and automatically  split  them up.  Also
--      splits up messages with "\n" or  literal newlines in them to be sent as
--      their own message.
--   * Robust message queue system  which  re-sends failed messages.  Sometimes
--      the server might give you  an  error  if  you send messages immediately
--      after the last.  Gopher works around that by saving  your  messages and 
--      verifying the response from the server.
--   * Support  for  all  chat types.  Alongside  public  messages,  Gopher  is
--      compatible  with  the  other  chat  channels.  Gopher also ensures that 
--      messages will  be  received in order that they're sent,  and corrects a
--      quirk with Battle.net whispers. Weak support for global channels.
--   * Seamless feel. Gopher should feel like there's nothing going on.
--     It hides  any error messages from  the  client,  and  provides  its  own
--      throttle library to ensure that outgoing chat is your #1 priority.
-----------------------------------------------------------------------------^-

local VERSION = 1

local Me = Gopher

if IsLoggedIn() then
	error( "Gopher can't be loaded on demand!" )
end

if Me then
	if Me.VERSION >= VERSION then
		-- Already loaded.
		return
	end
	
	---------------------------------------------------------------------------
	-- Cleanup here. Double check everything!
	---------------------------------------------------------------------------
	--if Gopher.VERSION == 1 then
	--
	--end

	---------------------------------------------------------------------------
else
	Me     = {}
	Gopher = Me
end

Me.VERSION = VERSION

-------------------------------------------------------------------------------
-- Here's our chat-queue system. 
--
-- Firstly we have the actual queue. This table contains the user's queued
--  chat messages they want to send.
--
-- Each entry has these fields. Most of these are the arguments you may pass
--  to SendChatMessage.
--    msg: The message text.
--    type: "SAY" or "EMOTE" etc.
--    arg3: Language index or club ID.
--    target: Channel, whisper target, BNet presence ID, or club stream ID.
--    prio: Message priority (lower numbers are sent before higher numbers).
--    id: Unique message ID. In the future this will help coordinate between
--         queues.
-- We have multiple channels to send messages of different types, since they
--  use different verification methods. For example, you can send a club 
--  message and a say message at the same time. This may be undesirable due
--  to unpredictable message ordering, but you can prevent that by inserting
--  a BREAK in the queue. (See QueueBreak)
--  
-- Queue 1: SAY, EMOTE, YELL, BNET
-- Confirmation: CHAT_MSG_SAY, CHAT_MSG_EMOTE, CHAT_MSG_YELL, 
--                CHAT_MSG_BN_WHISPER_INFORM
-- Failure: CHAT_MSG_SYSTEM
-- Fatal: CHAT_MSG_BN_WHISPER_PLAYER_OFFLINE
--
-- Queue 2: GUILD, OFFICER, CLUB
-- Confirmation: CHAT_MSG_GUILD, CHAT_MSG_OFFICER, 
--                CHAT_MSG_COMMUNITIES_CHANNEL
-- Failure: CLUB_ERROR
--
-- This is so that if you do SendChatMessage and then C_Club.SendMessage
--  at the same time, we can send both of these messages together. It's
--  mostly a feature meant to help Cross RP send its messages in unison.
--  Minimal improvement for normal cases.
Me.chat_queue    = {}
Me.channels_busy = {}
Me.message_id    = 1
Me.NUM_CHANNELS  = 2
-------------------------------------------------------------------------------
-- The way we dequeue is a little complex. It's not a plain FIFO anymore.
-- Firstly we sort by priority, lower numbers are sent before higher numbers.
-- Then, we try to keep our channels busy, and different channel types can
--  be sent in tandem. If you want to pair messages together, use a queue
--  break to halt the system until everything is free.
--
-- The guarantees provided are:
--   Chat messages of higher priorities are sent before lower priority.
--   Each channel's messages will always be sent and arrive in-order.
--   Using queue BREAKS, you can also guarantee message ordering cross-channel
--    or send messages together.
--
Me.traffic_priority = 1
-------------------------------------------------------------------------------
-- We have a system so third parties can process chat or listen for 
--  other Gopher events. It's much cleaner or safer to do chat processing with
--  these rather than them hooking SendChatMessage directly, since it will be
--  undefined if their hook fires before or after the message is cut up by our
Me.event_hooks = {    -- functions.

	-- CHAT_NEW is when the chat system processes a new message. This is
	--  when the message is fresh from SendChatMessage and no operations have
	--  been done with it yet. This event is skipped when Gopher is
	--  "suppressed".
	CHAT_NEW       = {};
	
	-- CHAT_QUEUE is when the chat system is about to queue a message which has
	--  gone through the cutter and other processes. CHAT_POSTQUEUE is after 
	--  the message is queued, and meant for post-hooks that trigger after the
	--  queue call.
	CHAT_QUEUE     = {};
	CHAT_POSTQUEUE = {};
	
	-- SEND_START is when the chat system becomes active and its trying to send
	--  messages and empty the queue.
	SEND_START     = {};
	
	-- SEND_FAIL is when the chat system detects a throttle failure or such,
	--  and will be working to recover or re-send.
	SEND_FAIL      = {};
	
	-- SEND_DEATH is when the chat system timed out and a hard reset is done 
	--  to recover.
	SEND_DEATH     = {};
	
	-- SEND_DEQUEUED is when the chat system has successfully sent and verified
	--  a message. The callback arguments will contain the message sent.
	SEND_DEQUEUED    = {};
	
	-- SEND_DONE is when the chat system has emptied its queue and goes back
	--  to being idle.
	SEND_DONE      = {};
}

Me.hook_stack = {} -- Our stack for hooks in case we're nesting things with
                   --  AddChatFromStartEvent.
-------------------------------------------------------------------------------
-- We count failures when we get a chat error. Some of the errors we get
--  (particularly from the communities API) are vague, and we don't really
--  know if we should keep re-sending. This limit is to stop resending after
Me.failures = 0                                --  so many of those errors.
Me.FAILURE_LIMIT = 5                           --
-------------------------------------------------------------------------------
-- Settings for the timers in the chat queue. CHAT_TIMEOUT is how much time it
--  will wait before assuming that something went wrong. In an ideal setup,
--  this is typically unnecessary, because chat messages are guaranteed to make
--  the server give you a response, be it the chat event or an error. If you
--  don't get a response, then you disconnect. However, if something goes wrong
--  on our end, we could typically be waiting forever for nothing, which is
--  what this is for. In other words, it's not a timeout for latency, it's a
--  timeout before assuming we screwed up.
-- CHAT_THROTTLE_WAIT is for when we intercept an error. We wait this many
--  seconds before resuming. We also have some latency detection code to
--  add on top, but this is the minimum value. The latency value isn't used or
--  necessary when we know that our message didn't send, like when sending
Me.CHAT_TIMEOUT       = 10.0                          -- community messages.
Me.CHAT_THROTTLE_WAIT = 3.0
-------------------------------------------------------------------------------
-- The community API lets you send messages that are as long as 4000 
--  characters. The textboxes are still limited to 255 characters, but we bump 
--  this up to a nice 400 characters per message. If you have too big of a
--  value, then it just makes the user interface unmanagable, since you cannot
--  partially scroll past one of the messages. Each message is one scroll tick.
-- This is also a thing with BNet whispers. `OTHER` is the default value for
--  other chat types. The chunk size will be 
--  `override[type] or default[type] or override.OTHER or default.OTHER`.
Me.default_chunk_sizes = {
	OTHER   = 255;
	CLUB    = 400;
	BNET    = 400;
	GUILD   = 400;
	OFFICER = 400;
}

if not C_Club then -- [7.x compat]
	Me.default_chunk_sizes.GUILD   = nil
	Me.default_chunk_sizes.OFFICER = nil
end

-------------------------------------------------------------------------------
-- Any chat type keys found in here will override the chunk size for a certain 
--  chat type. This is especially used by Cross RP for custom fake chat types 
--  that split on the 400 mark.
Me.chunk_size_overrides = {}

-------------------------------------------------------------------------------
-- We do some latency tracking ourselves, since the one provided by the game
--  isn't very accurate at all when it comes to recent events. The one in the
--  game is only updated every 30 seconds. We need an accurate latency value
--  immediately to detect lag spikes and then delay our handlers accordingly.
-- We measure latency by setting `recording` to the time we send a chat
Me.latency           = 0.1  -- message, and then get the time difference 
Me.latency_recording = nil  --         when we receive a server event.
                            -- Our value is in seconds.
-- You might have some questions, why I'm setting some table values to nil 
--  (which effectively does nothing), but it's just to keep things well 
--  defined up here.

-------------------------------------------------------------------------------
-- A lot of these definitions used to be straight local variables, but this is
--  a little bit cleaner, keeping things inside of this table, as well
--  as exposing it to the outside so we can do some easier diagnostics in case
--  something goes wrong down the line. Another great plus to exposing
--  everything like this is that other addons can see what we're doing. Sure,
--  the proper way is to make an API for something, but when it comes to the
--  modding scene, things can get pretty hacky, and it helps a bit to allow
--  others to mess with your code from the outside if they need to.
-------------------------------------------------------------------------------

function Me.AddCompatibilityLayers()
	if Me.compat then return end
	Me.compat = VERSION
	
	Me.MisspelledCompatibility()
	Me.TonguesCompatibility()
	Me.UCMCompatibility()
end

-------------------------------------------------------------------------------
-- Handle compatibility for the Misspelled addon.
--
function Me.MisspelledCompatibility()
	if not Misspelled then return end
	
	-- The Misspelled addon inserts color codes that are removed in its own
	--  hooks to SendChatMessage. This isn't ideal, because it can set up its
	--  hooks in the wrong "spot". In other words, its hooks might execute 
	--  AFTER we've already cut up the message to proper sizes, meaning that 
	--  it's going to make our slices even smaller, filled with a lot of empty
	--  space.
	-- What we do in here is unhook that code and then do it ourselves in one
	Misspelled:Unhook( "SendChatMessage" )	      -- of our own chat filters. 
	Me.Listen( "CHAT_NEW", function( text, chat_type, arg3, target, ... )
		text = Misspelled:RemoveHighlighting( text )
		return text, chat_type, arg3, target, ...
	end)
end

-------------------------------------------------------------------------------
-- Please read the following comments in your most maniacal voice, complete
--  with evil cackles. I almost gave up several times on this, and it's not
--  /really/ compatible, as I doubt Tongues' protocol even supports split
--  messages.
--
function Me.TonguesCompatibility()
	if not Tongues then return end -- No Tongues.
	
	-- First... we want to kill Tongues' SendChatMessage hook. All it does is 
	--  pass execution to HandleSend. We'll unhook their SendChatMessage hook
	--  by turning HandleSend into a dummy function, and then hook HandleSend
	--  ourselves...
	local stolen_handle_send = Tongues.HandleSend
	local tongues_hook = Tongues.Hooks.Send
	Tongues.HandleSend = function( self, msg, type, langid, lang, channel )
		tongues_hook( msg, type, langid, channel )
	end
	
	-- We reset their saved function for their hook with something that
	--  lets us know that they want to make a call to it. Why is this even
	--  necessary...? Don't question it!
	local tongues_is_calling_send = false
	local outside_send_function = function( ... )
		tongues_is_calling_send = true
		-- We use pcall to ignore errors, so tongues_is_calling_send doesn't
		--  get stuck, and it's likely that we'll run into a handful of errors
		--  if we have Tongues loaded.
		local a,b,c,d = ...
		pcall( SendChatMessage, a, b, c, d )
		tongues_is_calling_send = false
	end
	
	Tongues.Hooks.Send = outside_send_function
	
	-- Now... inside of our chat filter, we know if we're doing an organic call
	--  or not... If it is, we replace this hook temporarily to use our most
	--  special function SendChatFromHook...
	
	local inside_send_function = function( ... )
		Me.SendChatFromHook( ... )
	end
	
	local tongues_accepted_types = {
		SAY           = true;
		EMOTE         = true;
		YELL          = true;
		PARTY         = true;
		GUILD         = true;
		OFFICER       = true;
		RAID          = true;
		RAID_WARNING  = true;
		INSTANCE_CHAT = true;
		BATTLEGROUND  = true;
		WHISPER       = true;
		CHANNEL       = true;
	}
	
	Me.Listen( "CHAT_NEW", function( msg, type, _, target )
		if not tongues_accepted_types[type:upper()] then
			-- Don't send any special types through tongues.
			return
		end
		
		if tongues_is_calling_send then
			-- If Tongues is calling this, then we just skip our filter.
			return
		end
		
		-- And then replace the hook and call their handle send.
		Tongues.Hooks.Send = inside_send_function
		
		local langID, lang = GetSpeaking() -- Tongues adds this global.
		
		-- We need to use pcall, otherwise our Hooks.Send is going to be
		--  botched if we break out of here from an error.
		pcall( stolen_handle_send, Tongues, msg, type, langID, lang, target )
		
		-- And then put it back...
		Tongues.Hooks.Send = outside_send_function
		
		-- :)
		return false
	end)
end

-------------------------------------------------------------------------------
function Me.UCMCompatibility()
	if not UCM then return end -- No UCM
end

-------------------------------------------------------------------------------
-- Called after player login (or reload). Time to set things up.
function Me.OnLogin()
	-- Delay this a little so we give time for their own OnLogin to trigger.
	C_Timer.After( 1.0, Me.AddCompatibilityLayers )
	Me.PLAYER_GUID = UnitGUID("player")
	
	-- Message hooking. These first ones are the public message types that we
	--  want to hook for confirmation. They're the ones that can error out if
	--                           they're hit randomly by the server throttle.
	Me.frame:RegisterEvent( "CHAT_MSG_SAY"   )
	Me.frame:RegisterEvent( "CHAT_MSG_EMOTE" )
	Me.frame:RegisterEvent( "CHAT_MSG_YELL"  )
	
	if C_Club then -- 7.x compat
		-- In 8.0, GUILD and OFFICER chat are no longer normie communication
		--  channels. They're just routed into the community API internally.
		Me.frame:RegisterEvent( "CHAT_MSG_COMMUNITIES_CHANNEL" )
		Me.frame:RegisterEvent( "CHAT_MSG_GUILD"   )
		Me.frame:RegisterEvent( "CHAT_MSG_OFFICER" )
		Me.frame:RegisterEvent( "CLUB_ERROR"       )
	end
	
	-- Battle.net whispers do have a throttle if you send too many, and they're
	--  also affected by the very stupid Battle.net misordering quirk. Send one
	--  at a time to be safe.
	Me.frame:RegisterEvent( "CHAT_MSG_BN_WHISPER_INFORM" )
	
	-- I didn't even know they had a dedicated event for this.
	Me.frame:RegisterEvent( "CHAT_MSG_BN_WHISPER_PLAYER_OFFLINE" )
	
	-- And finally we hook the system chat events, so we can catch when the
	--                         system tells us that a message failed to send.
	Me.frame:RegisterEvent( "CHAT_MSG_SYSTEM" )
	
	Me.hooks = {}
	
	-- Here's the main chat hooks for splitting messages.
	Me.hooks.SendChatMessage = SendChatMessage
	SendChatMessage          = Me.SendChatMessageHook
	Me.hooks.BNSendWhisper   = BNSendWhisper
	BNSendWhisper            = Me.BNSendWhisperHook
	if C_Club then -- [7.x compat]
		Me.hooks.ClubSendMessage = C_Club.SendMessage
		C_Club.SendMessage       = Me.ClubSendMessageHook
	end
	
	-- Here's where we add the feature to hide the failure messages in the
	-- chat frames, the failure messages that the system sends when your
	ChatFrame_AddMessageEventFilter( "CHAT_MSG_SYSTEM", -- chat gets
		function( _, _, msg, sender )                   --  throttled.
			-- `ERR_CHAT_THROTTLED` is the localized string.
			if Me.hide_failure_messages and msg == ERR_CHAT_THROTTLED then 
				-- Returning true from these callbacks block the message
				return true -- from showing up.
			end
		end)
end

-------------------------------------------------------------------------------
function Me.OnGameEvent( frame, event, ... )
	if event == "CHAT_MSG_SAY" or event == "CHAT_MSG_EMOTE"
	                                           or event == "CHAT_MSG_YELL" then
		Me.TryConfirm( event:sub( 10 ), select( 12, ... ))
	elseif event == "CHAT_MSG_COMMUNITIES_CHANNEL" then
		Me.OnChatMsgCommunitiesChannel( event, ... )
	elseif event == "CHAT_MSG_GUILD" or event == "CHAT_MSG_OFFICER" then
		Me.OnChatMsgGuildOfficer( event, ... )
	elseif event == "CHAT_MSG_BN_WHISPER_INFORM" then
		Me.TryConfirm( "BNET", Me.PLAYER_GUID )
	elseif event == "CLUB_ERROR" then
		Me.OnClubError( event, ... )
	elseif event == "CHAT_MSG_BN_WHISPER_PLAYER_OFFLINE" then
		Me.OnChatMsgBnOffline( event, ... )
	elseif event == "CHAT_MSG_SYSTEM" then
		Me.OnChatMsgSystem( event, ... )
	elseif event == "PLAYER_LOGIN" then
		Me.OnLogin()
	end
end

-------------------------------------------------------------------------------
-- A simple function to iterate over a plain table, and return the key of any
local function FindTableValue( table, value ) -- first value that matches the
	for k, v in pairs( table ) do             -- argument. `key` also being an
		if v == value then return k end       -- index for array tables.
	end
	-- Otherwise, we don't return anything; or in other words, we return nil...
end

-------------------------------------------------------------------------------
-- Gopher exposes a number of its execution points via events. These are
--  primarily for third party addons to monitor or adjust text that's sent by
--  the user at different points throughout our system.
-- 
-- The reason for this is to avoid any more hooking of the SendChatMessage
--  function itself. Normally an addon would hook SendChatMessage if they want
--  to insert something (like replacing a certain keyword on the way out, or
--  removing text) but with Gopher you don't know if you're going to get your 
--  hook called before OR after the text is split up into smaller sections. 
--  A clear problem with this, is that if you want to insert text, and the 
--  text is already cut up, then you're going to push text past the
--  255-character limit and some is going to get cut off.
-- 
-- The signature for the callback function (func) is:
--
--   function( text, chat_type, arg3, target )
--
-- Arguments passed to it are fairly straightforward, and the same are
--  passed to SendChatMessage.
--
--   text:      The message text.
--   chat_type: "SAY", "EMOTE" etc, also includes our custom 
--               types "BNET", "CLUB".
--   arg3:      Language ID (a number), or club ID
--   target:    Depending on chat_type this is either a channel name, a
--               whisper target, a presence ID, or a community stream ID.
--
--   Return false from this function to block the message from being sent--to
--    discard it. Return nil to do nothing, and let the message pass through.
--   Otherwise, `return text, chat_type, arg3, target` to modify the chat
--    message. Take extra care to make sure that you're only setting these to
--    valid values.
--
-- `point` is where you will hook the system. This can be:
-- "CHAT_NEW"       Hook at the start, the message is raw and hasn't been cut 
--                   up yet.
-- "CHAT_QUEUE"     Called before the message is about to be queued. This is a 
--                   cut and primped message and this hook may trigger multiple
--                   times for a single, longer message.
-- "CHAT_POSTQUEUE" Called right after the message is queued. You can't cancel
--                   or change the message from in here, and return values are
--                   ignored.
--
-- Returns `true` if the hook was added, and `false` if it already exists.
--
function Me.Listen( event, func )
	if not Me.event_hooks[event] then
		error( "Invalid event." )
	end
	
	if FindTableValue( Me.event_hooks[event], func ) then
		return false
	end
	
	table.insert( Me.event_hooks[event], func )
	return true
end

-------------------------------------------------------------------------------
-- You can also easily remove event hooks with this. Just pass in your args 
--  that you gave to Listen.
--
-- Returns `true` if the hook was removed, and `false` if it wasn't found.
--
function Me.StopListening( event, func )
	if not Me.event_hooks[event] then
		error( "Invalid event." )
	end
	
	local index = FindTableValue( Me.event_hooks[event], func )
	if index then
		table.remove( Me.event_hooks[event], index )
		return true
	end
	
	return false
end

-------------------------------------------------------------------------------
-- You can also view the list of event hooks with this. This returns a direct
--  reference to the internal table which shouldn't be touched from the 
--  outside. Use with caution. Other addons might not expect you to be messing
--                                                     with their functions.
function Me.GetEventHooks( event ) 
	return Me.event_hooks[event] 
end

-------------------------------------------------------------------------------
-- Okay, now for whatever reason, we have this special API so that CHAT_NEW
--  listeners can spawn new messages. Presumably, they're discarding the 
--  original, or they're attaching some metadata that's whispered or something.
-- Very weird uses, but look, this is literally just for Tongues.
-- Chat messages that are spawned using this do not go through your CHAT_NEW
--  event listener twice. When they're processed, the filter list resumes right 
--  after where yours was.
-- If you DO want to make a completely fresh message that goes through the
--  entire chain again, just make a direct call to AddChat.
--
-- `msg`, `chat_type`, `arg3`, `target`: The new chat message.
--
-- This should only be used from "CHAT_NEW" hooks.
--
function Me.AddChatFromStartEvent( msg, chat_type, arg3, target )
	local filter_index = 0
	local filter = Me.hook_stack[#Me.hook_stack]
	if filter then
		for k,v in pairs( Me.chat_hooks["CHAT_NEW"] ) do
			if v == filter then
				filter_index = k
				break
			end
		end
	end
	
	Me.AddChat( msg, chat_type, arg3, target, filter_index + 1 )
end

-------------------------------------------------------------------------------
-- Sometimes you might want to send a chat message that bypasses Gopher's
--  filters. This is dangerous, and you should know what you're doing.
-- Basically, it's for funky protocol stuff where you don't want your message
--  to be touched, or even cut up. You'll get errors if you try to send
--  messages too big.
-- Messages that bypass the splitter still go through Gopher's queue system
--  with all guarantee's attached. CHAT_NEW is skipped, but QUEUE and POSTQUEUE
--  still trigger.
-- Calling this affects the next intercepted chat message only and then it
--  resets itself.
function Me.Suppress()
	Me.suppress = true
end

-------------------------------------------------------------------------------
-- This lets you pause the chat queue so you can load it up with messages
--  first, mainly for you to insert different priorities without the lower ones
--  firing before you're done feeding the queue. This automatically resets
--  itself, and you need to call it for each message added. Call StartQueue
--  when you're done adding messages.
--
function Me.PauseQueue()
	Me.queue_paused = true
end

-------------------------------------------------------------------------------
-- This is a feature added mainly for Cross RP, to keep the text protocol's
--  traffic away from clogging chat text from going through. Higher numbers are
--  always sent after lower priority numbers. (1 is highest priority)
-- If you're just sending chat, you likely won't ever need this. It's also
--  automatically reset after sending a chat message, and you need to call it
--  each time you want to send a low priority message.
function Me.SetTrafficPriority( priority )
	Me.traffic_priority = priority
end

function Me.GetTrafficPriority()
	return Me.traffic_priority
end

-------------------------------------------------------------------------------
-- Insert an entry into the chat queue, respecting priority.
--
local function ChatQueueInsert( entry )
	local insert_index = #Me.chat_queue+1
	for k, v in ipairs( Me.chat_queue ) do
		if v.prio > entry.prio then
			insert_index = k
			break
		end
	end
	table.insert( Me.chat_queue, insert_index, entry )
end

-------------------------------------------------------------------------------
-- Inserts a BREAK into the queue. This is a special message that doesn't allow
--  grouping across the break. This has limited purpose, but Cross RP uses it
--  to group messages together with the club channels.
--
-- Examples:
--   SAY   HELLO         \ Sent together, as they're different channels
--   CLUB  RELAY_HELLO   /
--   CLUB  SOMETHING     \ Sent together with next batch.
--   SAY   HELLO         / 
--   CLUB  RELAY_HELLO   - This RELAY message is sent too late, and by itself.
--
--   SAY   HELLO         \ Sent together, as they're different channels
--   CLUB  RELAY_HELLO   /
--   CLUB  SOMETHING     \ Sent together with next batch.
--   BREAK               -- Cuts grouping.
--   SAY   HELLO         \ Sent together properly.
--   CLUB  RELAY_HELLO   /
--
-- This may have more uses in the future. Another example.
--   SAY   HELLO        -> Sent on first batch.
--   BREAK              -> Waits for queue to empty
--   CLUB  YES          -> Sent in order one after another.
--   CLUB  YES          -
--   CLUB  YES          - If the break wasn't there, all of these could be
--   CLUB  YES          -  sent while that important HELLO up there was still
--                      -  pending. See?
--
-- What BREAK also does is waits for the throttler to catch up on BURST
--  bandwidth, essentially making it guaranteed that you're going to be sending
--  your grouped messages in a tight pair.
--
function Me.QueueBreak( priority )
	priority = priority or 1
	ChatQueueInsert({ 
		type = "BREAK";
		prio = priority;
	})
end

-------------------------------------------------------------------------------
-- Causes Gopher to use this chunk size when cutting up messages of this chat
--  type.
-- Pass nil as size to remove an override.
-- Pass "OTHER" as the `chat_type` to override all default settings.
-- Chunk size is calculated as:
--  `overrides[type] or defaults[type] or overrides.OTHER or defaults.OTHER`
-- `defaults` is the internal default chunk sizes.
--
function Me.SetChunkSizeOverride( chat_type, chunk_size )
	Me.chunk_size_overrides[chat_type] = chunk_size
end

-------------------------------------------------------------------------------
-- Function for splitting text on newlines or newline markers (literal "\n").
--
-- Returns a table of lines found in the text {line1, line2, ...}. Doesn't 
--  include any newline characters or marks in the results. If there aren't any
--  newlines, then this is going to just return { text }.
--                               --
function Me.SplitLines( text )   --
	-- We still want to send empty messages for AFK, DND, etc.
	if text == "" then return {""} end
	-- We merge "\n" into LF too. This might seem a little bit unwieldy, right?
	-- Like, you're wondering what if the user pastes something
	--  like "C:\nothing\etc..." into their chatbox to send to someone. It'll
	--          ^---.
	--  be caught by this and treated like a newline.
	-- Truth is, is that the user can't actually type "\n". Even without any
	--  addons, typing "\n" will cut off the rest of your message without 
	--  question. It's just a quirk in the API. Probably some security measure
	--  or some such for prudence? We're just making use of that quirk so
	--                             -- people can easily type a newline mark.
	text = text:gsub( "\\n", "\n" ) --
	                                --
	-- It's pretty straightforward to split the message now, we just use a 
	local lines = {}                        -- simple pattern and toss it 
	for line in text:gmatch( "[^\n]+" ) do  --  into a table.
		table.insert( lines, line )         --
	end                                     --
	                                        --
	-- We used to handle this a bit differently, which was pretty nasty in
	--  regard to chat filters and such. It's a /little/ more complex now,
	return lines -- but a much better solution in the end.
end

-------------------------------------------------------------------------------
-- Our hooks just basically do some routing, rearrange the parameters for our
-- main AddChat function.
--
function Me.SendChatMessageHook( msg, chat_type, language, channel )
	Me.AddChat( msg, chat_type, language, channel )
end

function Me.BNSendWhisperHook( presence_id, message_text ) 
	Me.AddChat( message_text, "BNET", nil, presence_id )
end

function Me.ClubSendMessageHook( club_id, stream_id, message )
	Me.AddChat( message, "CLUB", club_id, stream_id )
end

-------------------------------------------------------------------------------
-- Returns the club ID for the user's guild, or nil if they aren't in a guild
--  or if it can't otherwise find it.
--
local function GetGuildClub()
	-- This is kind of poor that we have to do this scan for every chat
	--  message. But it helps to think about it like some sort of block of
	--  generic code that has to be run for sending chat. Chat isn't all
	--  that common though, so we can get away with stuff like this.
	for _, club in pairs( C_Club.GetSubscribedClubs() ) do
		if club.clubType == Enum.ClubType.Guild then
			return club.clubId
		end
	end
end

-------------------------------------------------------------------------------
-- Gets the stream for the main "GUILD" channel or "OFFICER" channel.
-- Type is from Enum.ClubStreamType, and it should be
--  Enum.ClubStreamType.Guild or Enum.ClubStreamType.Officer
-- Returns nil if not in a guild or if it can't find it.
local function GetGuildStream( type )
	local guild_club = GetGuildClub()
	if guild_club then
		for _, stream in pairs( C_Club.GetStreams( guild_club )) do
			if stream.streamType == type then
				return guild_club, stream.streamId
			end
		end
	end
end

function Me.FireEventEx( event, start, ... )
	start = start or 1
	local args = {...}
	for index = start, #Me.chat_hooks[event] do
		table.insert( Me.hook_stack, Me.event_hooks[event][index] )
		local args2 = { pcall( Me.event_hooks[event][index], event, unpack( args )) }
		table.remove( Me.hook_stack )
		
		-- [1] is pcall status, [2] is first return value
		if args2[1] then
			-- If an event hook returns `false` then we cancel the chain.
			if args2[2] == false then
				return false
			elseif args2[2] then
				-- Otherwise, if it's non-nil, we assume that they're changing
				--  the arguments on their end, so we replace them with the
				args = args2 -- return values.
				table.remove( args, 1 ) -- remove pcall status
			end
			-- If the hook returned nil, then we don't do anything to the
			--  event args.
		else
			-- The hook errored
			if Me.print_listener_errors then
				print( ("Gopher Event Listener Error: %s"):format( args2[2] ))
			end
		end
	end
	return unpack( args )
end

function Me.FireEvent( event, ... )
	return Me.FireEventEx( event, 1, ... )
end

function Me.ResetState()
	Me.suppress     = false
	Me.queue_paused = false
end

-------------------------------------------------------------------------------
-- This is where the magic happens...
--
-- Our parameters don't only accept the ones from SendChatMessage.
-- We also add the chat type "BNET" where target is the presence ID, and "CLUB"
--  where arg3 is the club ID, and target is the stream ID.
--
-- `hook_start` is for SendChatFromFilter where the filter function is
--  spawning new chat messages.
--
function Me.AddChat( msg, chat_type, arg3, target, hook_start )
	if Me.suppress then
		-- We don't touch suppressed messages.
		Me.FireEvent( "QUEUE", msg, chat_type, arg3, target )
		Me.QueueChat( msg, chat_type, arg3, target )
		Me.FireEvent( "POSTQUEUE", msg, chat_type, arg3, target )
		Me.ResetState()
		return
	end
	
	msg = tostring( msg or "" )
	
	msg, chat_type, arg3, target = 
		Me.FireEventEx( "START", hook_start, msg, chat_type, arg3, target )
		
	if msg == false then
		Me.ResetState()
		return 
	end
	
	-- Now we cut this message up into potentially several pieces. First we're
	--  passing it through this line splitting function, which gives us a table
	msg = Me.SplitLines( msg )  -- of lines, or just { msg } if there aren't
	                              --  any newlines.
	chat_type = chat_type:upper()
	
	-- We do some work here in rerouting some messages to avoid using
	--  SendChatMessage, specifically with ones that use the Club API. It's
	--  probably sending it there internally, but we can do that ourselves
	--  so we can take advantage of the fact that the Club API allows a 
	--  larger max message length. By default we split those types of messages
	--  up at the 400 character mark rather than 255.
	local chunk_size = Me.chunk_size_overrides[chat_type]
	                      or Me.chunk_size_defaults[chat_type]
	                      or Me.chunk_size_overrides.OTHER
	                      or Me.chunk_size_defaults.OTHER
	if chat_type == "CHANNEL" then
		-- Chat type CHANNEL can either be a normal legacy chat channel, or the
		--  user can be typing in a chat channel that's linked to a community
		--  channel. This is only done through the normal chatbox. If you type
		--  in the community panel, it goes straight to C_Club:SendMessage.
		local _, channel_name = GetChannelName( target )
		if channel_name then
			-- GetChannelName returns a specific string for club channels:
			--   Community:<club ID>:<stream ID>
			local club_id, stream_id = 
			                      channel_name:match( "Community:(%d+):(%d+)" )
			if club_id then
				-- This is a community message, reroute this message to use
				--  C_Club directly...
				chat_type  = "CLUB"
				arg3       = club_id
				target     = stream_id
				chunk_size = Me.club_chunk_size
				chunk_size = Me.chunk_size_overrides.CLUB
				              or Me.chunk_size_defaults.CLUB
							  or Me.chunk_size_overrides.OTHER
							  or Me.chunk_size_defaults.OTHER
			end
		end
	elseif chat_type == "GUILD" or chat_type == "OFFICER" then
		-- For GUILD and OFFICER, we want to reroute these too to use the
		--  Club API so we can take advantage of it just like we do with
		--  channels. GUILD and OFFICER are already using the Club API
		--  internally at some point, and guilds have their own club ID
		--  and streams.
		if C_Club then -- 7.x compat
			local club_id, stream_id = 
				GetGuildStream( chat_type == "GUILD" 
									and Enum.ClubStreamType.Guild 
									or Enum.ClubStreamType.Officer )
			if not club_id then
				-- The client right now doesn't actually print this message, so
				--  we're helping it out a little bit. If it does start
				--  printing it on its own, then remove this.
				local info = ChatTypeInfo["SYSTEM"];
				DEFAULT_CHAT_FRAME:AddMessage( ERR_GUILD_PLAYER_NOT_IN_GUILD, 
				                               info.r, info.g, info.b, 
											   info.id );
				-- They aren't in a guild though, so we cancel this message
				--  from being queued.
				return
			end
			chat_type  = "CLUB"
			arg3       = club_id
			target     = stream_id
		end
	end
	
	-- And we iterate over each, pass them to our main splitting function 
	--  (the one that cuts them to smaller chunks), and then feed them off
	--  to our main chat queue system. That call might even bypass our queue
	--  or the throttler, and directly send the message if the conditions
	--  are right. But, otherwise this message has to wait its turn.
	for _, line in ipairs( msg ) do
		local chunks = Me.SplitMessage( line, chunk_size )
		for i = 1, #chunks do
			local chunk_msg, chunk_type, chunk_arg3, chunk_target =
				Me.FireEvent( "QUEUE", chunks[i], chat_type, arg3, target )
				
			if chunk_msg then
				Me.QueueChat( chunk_msg, chunk_type, chunk_arg3, chunk_target )
				Me.FireEvent( "POSTQUEUE", chunk_msg, chunk_type, 
				                                     chunk_arg3, chunk_target )
			end
		end
	end
	
	Me.ResetState()
end

-------------------------------------------------------------------------------
-- This table contains patterns for strings that we want to keep whole after
--  the message is cut up in SplitMessage. Chat links can have spaces in them
--  but if they're matched by this, then they'll be protected.
Me.chat_replacement_patterns = {
	-- The code below only supports 9 of these (because it uses a single digit
	--  to represent them in the text).
	-- Right now we just have this pattern, for catching chat links.
	-- Who knows how the chat function works in WoW, but it has vigorous checks
	--  (apparently) to allow any valid link, along with the exact color code
	--  for them.
	"(|cff[0-9a-f]+|H[^|]+|h[^|]+|h|r)"; -- RegEx's are pretty cool,
	                                     --  aren't they?
	-- I had an idea to also keep addon links intact, but there haven't really
	--  been any complaints, and this could potentially result in some breakage
	--  from people typing a long message (which breaks the limit) surrounded
	--  by brackets (perhaps an OOC message).
	--
	-- Like this: "%[.-%]";
	--
	-- A little note here, that the code below will break if there is a match
	-- that's shorter than 4 (or 5?) characters.
}

-------------------------------------------------------------------------------
-- Here's our main message splitting function. You pass in text, and it spits
--  out a table of smaller message (or the whole message, if it's small
--  enough.)
-- text: Text to split up.
-- chunk_size: Size of the chunks to output. 
--             Defaults to Me.default_chunk_sizes.OTHER
-- splitmark_start: The text to add to the start of messages 2..N.
-- splitmark_end:   The text to add to the end of messages 1..N-1.
-- chunk_prefix: Text to prepend all chunks returned, e.g. "NPC says: "
-- chunk_suffix: Text to append to all chunks returned.
--
function Me.SplitMessage( text, chunk_size, splitmark_start, splitmark_end,
                                                   chunk_prefix, chunk_suffix )
	chunk_size      = chunk_size or Me.default_chunk_sizes.OTHER
	chunk_prefix    = chunk_prefix or ""
	chunk_suffix    = chunk_suffix or ""
	splitmark_start = splitmark_start or Me.splitmark_start
	splitmark_end   = splitmark_end or Me.splitmark_end
	local pad_len   = chunk_prefix:len() + chunk_suffix:len()
	
	-- For short messages we can not waste any time and return immediately
	--                 if they can fit within a chunk already. A nice shortcut.
	if text:len() + pad_len <= chunk_size then
		return { chunk_prefix .. text .. chunk_suffix }
	end
	
	-- Otherwise, we gotta get our hands dirty. We want to preserve links (or
	--  other defined things in the future) from being split apart by the
	--  cutting code below. We do that by turning them to solid strings that
	local replaced_links = {} -- contain an ID code for reversing at the end.
	                          --
	for index, pattern in ipairs( Me.chat_replacement_patterns ) do
		text = text:gsub( pattern, function( link )
			-- This turns something like "[Chat Link]" into "12x22222223",
			--  essentially obliterating that space in there so this "word"
			--  is kept whole. The x there is used to identify the pattern
			--  that matched it. We save the original text in replaced_links
			--  one on top of the other. The index is used to know which
			--  replacement list to pull from.
			-- replaced_links is a table of lists, and we index it by this `x`.
			-- In here, we just throw it on whichever list this pattern belongs
			replaced_links[index] = replaced_links[index] or {} -- to.
			table.insert( replaced_links[index], link )
			return "\001\002" .. index 
			       .. ("\002"):rep( link:len() - 4 ) .. "\003"
		end)
	end
	
	-- A little bit of preprocessing goes a long way somtimes, like this, where
	--  we add whitespace directly to the splitmarks rather than applying it 
	if splitmark_start ~= "" then              -- separately below in the loop.
		splitmark_start = splitmark_start .. " "
	end                                       -- If they are empty strings,
	if splitmark_end ~= "" then               --  then they're disabled. This 
		splitmark_end = " " .. splitmark_end  --  all works smoothly below in 
	end                                       --  the main part.
	
	local chunks = {} -- Our collection of text chunks. The return value. We'll
	                  --  fill it with each section that we cut up.
	while( text:len() + pad_len > chunk_size ) do
		-- While in this loop, we're dealing with `text` that is too big to fit
		--  in a single chunk (max 255 characters or whatever the override is
		--  set to [we'll use the 255 figure everywhere to keep things
		--  simple]).
		-- We actually start our scan at character 256, because when we do the
		--  split, we're excluding that character. Either deleting it, if it's
		--  whitespace, or cutting right before it.
		-- We scan backwards for whitespace or an otherwise suitable place to
		--  break the message.
		for i = chunk_size+1 - splitmark_end:len() - pad_len, 1, -1 do
			--               ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
			-- Don't forget to leave some extra room!
			local ch = string.byte( text, i )
			
			-- We split on spaces (ascii 32) or a start of a link (inserted
			if ch == 32 or ch == 1 then -- above).
				
				-- If it's a space, then we discard it.
				-- Otherwise we want to preserve this character and keep it in
				local offset = 0                -- the next chunk.
				if ch == 32 then offset = 1 end --
				
				-- An interesting note here is for people who like to do
				--  certain punctuation like ". . ." where you have spaces
				--  between your periods. It's kind of ugly to split on that
				--  but there's a special character called "no-break space" 
				--  that you can use instead to keep that term a whole word.
				-- I'm considering writing an addon that automatically fixes up
				--  your text with some preferential things like that.
				table.insert( chunks, chunk_prefix .. text:sub( 1, i-1 ) 
				                             .. splitmark_end .. chunk_suffix )
				text = splitmark_start .. text:sub( i+offset )
				break
			end
			
			-- If the scan reaches all the way to the last bits of the string,
			if i <= 16 then  -- then that means there's a REALLY long word.
				-- In that case, we just break the message wherever. We just
				--  need to take care to not break UTF-8 character strings.
				-- Who knows, maybe it might not even be abuse. Maybe it's
				--  just a really long sentence of Kanji glyphs or something??
				-- (I don't know how Japanese works.)
				--
				-- We're starting over this train.
				for i = chunk_size+1 - splitmark_end:len() - pad_len, 1, -1 do
					local ch = text:byte(i)
					
					-- Now we're searching for any normal ASCII character, or
					--  any start of a UTF-8 character. UTF-8 bit format for 
					--  the first byte in a multi-byte character is always 
					--  `11xxxxxx` the following bytes are all `10xxxxxx`, so
					if (ch >= 32 and ch < 128)  --  our resulting criteria is 
					        or (ch >= 192) then  --  [32-128] and [192+].
						table.insert( chunks, chunk_prefix 
						                       .. text:sub( 1, i-1 ) 
						                         .. splitmark_end  
						                           .. chunk_suffix )
						text = splitmark_start .. text:sub( i )
						break
					end
					-- We could have done this search in the above loop, keep
					--  track of where the first valid character is, keep 
					--  things DRY, but this is a heavy corner case, and we
					--  don't need to slow down the above loop for it.
					
					-- If we reach halfway through the text without finding a
					--  valid character to split at, then there is some clear 
					--  abuse going on. (Actually, we should have found one in 
					if i <= 128 then  -- the first few bytes.)
						return {""}   -- In this case, we just obliterate
					end               --  whatever nonsense we were fed.
				end                   -- No mercy.
				
				break -- Make sure that we aren't repeating the outer loop.
			end
		end
	end

	-- `text` is now the final chunk that can fit just fine, so we throw that
	table.insert( chunks, chunk_prefix .. text .. chunk_suffix ) -- in too!
	
	-- We gotta put the links back in the text now.
	-- This is neat, isn't it? We allow up to 9 replacement patterns (and any
	--  more is gonna be pushing it). Simple enough, we grab strings from the
	--  saved values and increment whichever index we're using.
	local counters = {1,1,1, 1,1,1, 1,1,1}
	
	for i = 1, #chunks do 
		chunks[i] = chunks[i]:gsub("\001\002(%d)\002*\003", function(index)
			-- Now, you could just write
			--  `index = tonumber(index)` to convert this number, but we
			--  can do a dumb trick. Since it's a single digit, we just
			--  steal the ASCII value directly, and subtract 48 (ascii for 0)
			index = index:byte(1) - 48 -- from it. I imagine this is way 
			                           --  faster than tonumber(index).
			-- But honestly little hacks like this which show little to no
			--  performance gain in practice (this code is hardly called)
			--  just makes the code uglier. It's just something to keep in
			--  mind when doing more performance intensive operations.
			-- Anyway, we needed a number value to index our counters and
			local text = replaced_links[index][counters[index]] -- replaced
			counters[index] = counters[index] + 1              -- links table.
			
			-- We really shouldn't be /missing/ our replacement value. If this
			--  happens, then there's likely malicious text in the string we
			--  got. A valid case of this actually happening without anyone
			--  being deliberate is some sort of addon inserting hidden data
			--  into the message which they forgot to (or haven't yet) removed.
			return text or "" -- They could be removing it shortly after in
		end)                  --  some hooks or something.
	end
	
	return chunks
end
			
-------------------------------------------------------------------------------
local QUEUED_TYPES = { -- These are the types that aren't passed directly to
	SAY     = CHANNEL_SAY; --  the throttler for output. They're queued and sent
	EMOTE   = CHANNEL_SAY; --  one at a time, so that we can verify if they went
	YELL    = CHANNEL_SAY; --  through or not.
	BNET    = CHANNEL_SAY;     
	GUILD   = CHANNEL_CLUB; -- We handle GUILD and OFFICER like this too since
	OFFICER = CHANNEL_CLUB; --  they're also treated like club channels in 8.0.
	CLUB    = CHANNEL_CLUB; -- Essentially, anything that can fail from throttle
}                      --  or other issues should be put in here.
-- In 1.4.2 we also have a few different queue types to send traffic with
--  different handlers at the same time.

-- [[7.x compat]] Remove this after 7.x; we don't handle GUILD/OFFICER like
if not C_Club then             -- this.
	QUEUED_TYPES.GUILD   = nil;
	QUEUED_TYPES.OFFICER = nil;
end

-------------------------------------------------------------------------------
-- This is our main entry into our chat queue. Basically we have the same
--  parameters as the SendChatMessage API. For BNet whispers, set `type` to 
--  "BNET" and `target` to the bnetAccountID. For Club messages, `type` is 
--  "CLUB", `arg3` is the club ID, and `target` is the stream ID.
-- Normal parameters:
--  msg     = Message text
--  type    = Message type, e.g "SAY", "EMOTE", "BNET", "CLUB", etc.
--  arg3    = Language index or club ID.
--  target  = Whisper target, bnetAccountID, channel name, or stream ID.
--
function Me.QueueChat( msg, type, arg3, target )
	type = type:upper()
	
	local msg_pack = {
		msg    = msg;
		type   = type;
		arg3   = arg3;
		target = target;
		id     = Me.message_id;
		prio   = Me.traffic_priority;
	}
	Me.message_id = Me.message_id + 1
	
	local queue_index = QUEUED_TYPES[type]
	
	-- Now we've got two paths here. One leads to the chat queue, the other
	--  will directly send the messages that don't need to be queued.
	--  SAY, EMOTE, and YELL are affected by the server throttler. BNET isn't,
	--  but we treat it the same way to correct the out-of-order bug.
	if queue_index then
		-- A certain problem with this queue is that sometimes we'll be stuck
		--  waiting for a response from the server, but nothing is coming
		--  because we weren't actually able to send the chat message. There's
		--  no easy way to tell if a chat message is valid, or if the player 
		--  was talking to a valid recipient etc. In the future we might handle
		--  the "player not found" message or what have you for battle.net
		--  messages. Otherwise, we need to do our best to make sure that this
		--  is a valid message, ourselves.
		-- First of all, we can't send an empty message.
		if msg == "" then return end
		-- Secondly, we can't send swastikas. The server just rejects these
		--  silently, and your chat gets discarded.
		if msg:find( "卍" ) or msg:find( "卐" ) then return end
		if UnitIsDeadOrGhost( "player" ) and (type == "SAY" 
		--[[ Thirdly, we can't send  ]]    or type == "EMOTE" 
		--[[ public chat while dead. ]]    or type == "YELL") then 
			-- We still want them to see the error, which they won't normally
			--  see if we don't do it manually, since we're blocking
			--                                    SendChatMessage.
			UIErrorsFrame:AddMessage( ERR_CHAT_WHILE_DEAD, 1.0, 0.1, 0.1, 1.0 )
			return
		end
		
		ChatQueueInsert( msg_pack )
		
		if Me.queue_paused then
			return
		end
		
		Me.StartQueue()
		
	else -- For other message types like party, raid, whispers, channels, we
		 -- aren't going to be affected by the server throttler, so we go
		Me.CommitChat( msg_pack )  -- straight to putting these
	end                            --  messages out on the line.
end

function Me.AnyChannelsBusy()
	for i = 1,MY_NUM_CHANNELS do
		if Me.channels_busy[i] then return true end
	end
end

function Me.AllChannelsBusy()
	for i = 1,MY_NUM_CHANNELS do
		if not Me.channels_busy[i] then return false end
	end
	return true
end

-------------------------------------------------------------------------------
-- Execute the chat queue.
--
function Me.StartQueue()
	Me.queue_paused = false
	-- It's safe to call this function whenever for whatever. If the queue is
	--  already started, or if the queue is empty, it does nothing.
	
	-- I always like APIs that have simple checks like that in place. Sure it
	--  might be a /little/ bit less efficient at times, but the resulting code
	--  on the outside as a result is usually much cleaner. Boilerplate belongs
	--  in the library, right? First thing we do when the system starts is
	--  send the first message in the chat queue. Like this.
	Me.ChatQueueNext()
end

-------------------------------------------------------------------------------
-- Send the next message in the chat queue.
--
function Me.ChatQueueNext()
	
	-- This is like the "continue" function for our chat queue system.
	-- First we're checking if we're done. If we are, then the queue goes
	if #Me.chat_queue == 0 then -- back to idle mode.
		if not Me.AnyChannelsBusy() and Me.sending_active then
			Me.FireEvent( "SEND_DONE" )
			--*Me.SendingText_Hide()
			Me.failures       = 0
			Me.sending_active = false
		end
		return
	end
	
	Me.sending_active = true
	Me.FireEvent( "SEND_START" )
	-- Otherwise, we're gonna send another message. 
	--*Me.SendingText_ShowSending()
	
	local i = 1
	while i <= #Me.chat_queue do
		local q = Me.chat_queue[i]
		if q.type == "BREAK" then
			if Me.AnyChannelsBusy() then
				break
			else
				if Me.ThrottlerHealth() < 25 then
					Me.Timer_Start( "throttle_break", "ignore", 0.1, 
					                                         Me.ChatQueueNext )
					return
				end
				table.remove( Me.chat_queue, i )
			end
		else
			local channel = QUEUED_TYPES[q.type]
			if not Me.channels_busy[channel] then
				Me.Timer_Start( "channel_"..channel, "push", CHAT_TIMEOUT, 
				                                        Me.ChatDeath, channel )
				Me.CommitChat( q )
				Me.channels_busy[channel] = q
				if Me.AllChannelsBusy() then
					break
				end
			end
			i = i + 1
		end
	end
	
	if not Me.AnyChannelsBusy() then
		--@debug@
		if #Me.chat_queue ~= 0 then
			error( "Chat queue not empty when returning from ChatQueueNext" )
		end
		--@end-debug@
		Me.SendingText_Hide()
		Me.failures = 0
	end
	
	-- We fetch the first entry in the chat queue and then "commit" it. Once
	--  it's sent like that, we're waiting for an event from the server to 
	--  continue. This can continue in three ways.
	-- (1) We see that our message has been sent, by seeing it mirrored back
	--  from the server, and then we delete this message and send the next
	--  one in the queue.
	-- (2) The server throttles us, and we get an error. We intercept that
	--  error, wait a little bit, and then retry sending this message. This
	--  step can repeat indefinitely, but usually only happens once or twice.
	-- (3) The chat timer times out before we get any sort of response.
	--  This happens under heavy latency or when something prevents our
	--  message from being sent (and we don't know it). We want to do a hard
	--  reset in that case so we don't get stuck in a failed state.
end

Me.frame = Me.frame or CreateFrame( "Frame" )
Me.frame:UnregisterAllEvents()
Me.frame:RegisterEvent( "PLAYER_LOGIN" )
Me.frame:SetScript( OnEvent, Me.OnGameEvent )