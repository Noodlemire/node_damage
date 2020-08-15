--[[
Node Damage and Repair System
Copyright (C) 2020 Noodlemire

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this library; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
--]]

--mod-specific global storage
node_damage = {}

--Get the node_damage version of an item's name.
--In the original name, the comma is gsubbed into an underscore in order to comply with naming standards.
local function get_node_damage_name(name, i)
	return "node_damage:"..(name:gsub(":", "_")).."_"..i
end

--Check if any particular node is valid for crackification.
local function node_is_valid(name)
	--Get the existing definition for this item.
	local def = minetest.registered_items[name]

	--Return true if all of the following is true:
	--The definition exists
	--This item is not something that would immediately be dug up anyways
	--This item isn't already cracked
	--This item is a node
	--This item doesn't originate from this mod.
	--This item can be destroyed
	--This item is visible
	return (def and minetest.get_item_group(name, "dig_immediate") == 0 
		and minetest.get_item_group(name, "node_damage") == 0 and def.type == "node" and def.mod_origin ~= "node_damage" 
		and def.diggable and def.drawtype ~= "airlike")
end

--Once every mod has loaded and therefore every node has been registered...
minetest.register_on_mods_loaded(function()
	--For each registered item...
	for name, def in pairs(minetest.registered_items) do
		--If there's a valid node...
		if node_is_valid(name) then
			local ndef = {node_damaged_name = get_node_damage_name(name, 1)}
			minetest.override_item(name, ndef)

			--For each of the cracked stages...
			for i = 1, 3 do
				--Copy the base node's definition and remove information from the copy that can't be overridden.
				def = table.copy(minetest.registered_items[name])
				--def.name = get_node_damage_name(name, i)
				--def.mod_origin = "node_damage"

				--Give it the not_in_creative_inventory and node_damage groups
				--The exact number of node_damage can be used to know how damaged a node is.
				def.groups = def.groups or {}
				def.groups.not_in_creative_inventory = 1
				def.groups.node_damage = i

				--If the node doesn't already define drops, make the cracked nodes only drop their fully repaired version.
				if not def.drop then
					def.drop = name
				end

				--If the damage stage is 1, repairing it gives the base node.
				if i == 1 then
					def.node_repaired_name = name
				--Otherwise, it gives the damage stage one less than this one.
				else
					def.node_repaired_name = get_node_damage_name(name, i - 1)
				end

				--If the damage stage isn't the highest, 3, damaging it gives the next stage of damage.
				if i ~= 3 then
					def.node_damaged_name = get_node_damage_name(name, i + 1)
				else
					--Stage 3 of damage doesn't place a new node when damage. They're just destroyed.
					def.node_damaged_name = nil
				end

				--If this node defines textures...
				if def.tiles then
					--For each tile...
					for k, tile in pairs(def.tiles) do
						--If the tile is just a string, overlay cracks onto the tile
						if type(tile) == "string" then
							def.tiles[k] = tile.."^node_damage_"..i..".png"
						--If there's a name field, overlay cracks onto the name
						elseif def.tiles[k].name then
							def.tiles[k].name = tile.name.."^node_damage_"..i..".png"
						--If there's an image field (deprecated), overlay cracks onto the image
						elseif def.tiles[k].image then
							def.tiles[k].image = tile.image.."^node_damage_"..i..".png"
						--Otherwise, relay an error message.
						else
							minetest.log("error: Could not overlay "..dump(tile))
						end
					end
				else
					--Otherwise, relay an error message.
					minetest.log(name.." has no tiles.")
					break
				end

				--Finally, forcefully register a new node while skipping the mod name prefix check,
				--in order for it to work after all mods have been loaded.
				minetest.register_node(":"..get_node_damage_name(name, i), def)
			end
		end
	end
end)



--A function to damage a given node, as long as that's possible.
--pos: The location of the node to damage.
--node: Optional; the node itself. It there's already data, you can pass it along to save time, but this function can grab the data itself.
--digger: Optional; A person (ObjectRef) who is attacking this node. If its destroyed, that person will pick it up.
--num: Optional, defaults to 1; The amount of times to damage this node. 3 will destroy any node_damage node.
--Returns a boolean indicating success.
function node_damage.damage(pos, node, digger, num)
	--If the node itself wasn't provided, grab it from the provided position
	if not node then
		node = minetest.get_node(pos)
	end

	--By default, assume that there is no player directly causing the damage.
	local pname = ""

	--If there is a player, get that player's name instead.
	if digger then
		pname = digger:get_player_name()
	end

	--If this node is protected, fail.
	if minetest.is_protected(pos, pname) then
		return false
	end

	--Get the node's definition
	local def = minetest.registered_items[node.name]

	--If the def has no definition or specifies that it can't be dug right now, fail.
	if not def or (def.can_dig and def.can_dig()) then
		return false
	end

	--If it defines a next stage of damage, swap to that next stage.
	if def.node_damaged_name and minetest.registered_items[def.node_damaged_name] then
		minetest.swap_node(pos, {name = def.node_damaged_name, param1 = node.param1, param2 = node.param2})
	--Otherwise, if it doesn't because it's in the last stage of damage, destroy the node.
	elseif def.groups.node_damage == 3 then
		--If a digger was provided, use node_dig to give the node to them.
		if digger then
			minetest.node_dig(pos, node, digger)
		--Otherwise, use the standard dig_node. This leaves the drops on the ground.
		else
			minetest.dig_node(pos, node)
		end

		--If the node was dug up and left nothing behind, there's no need to apply more damage.
		if minetest.get_node(pos).name == "air" then
			return true
		end
	else
		--If it's not possible to damage this node, fail.
		return false
	end

	--If num was provided and it was more than 1...
	if num and num > 1 then
		--Call damage again, but with 1 less num.
		return node_damage.damage(pos, node, digger, num - 1)
	end

	--Getting to the end of the function is only possible upon success.
	return true
end

--The opposite of damage. Removes damage from a node, as long as its possible.
--pos: The location of the node to repair.
--node: Optional; the node itself. It there's already data, you can pass it along to save time, but this function can grab the data itself.
--fixer: Optional; A person (ObjectRef) who is repairing this node. Used to determine protection permission.
--num: Optional, defaults to 1; The amount of times to repair this node. 3 will repair any node that still exists.
--Returns a boolean indicating success.
function node_damage.repair(pos, node, fixer, num)
	--If the node itself wasn't provided, grab it from the provided position
	if not node then
		node = minetest.get_node(pos)
	end

	--By default, assume that there is no player directly causing the repair.
	local pname = ""

	--If there is a player, get that player's name instead.
	if fixer then
		pname = fixer:get_player_name()
	end

	--If this node is protected, fail.
	if minetest.is_protected(pos, pname) then
		return false
	end

	--Get the node's definition
	local def = minetest.registered_items[node.name]

	--If there is no definition for this node, fail.
	if not def then
		return false
	end

	--If the definition has the name of a less damaged node to switch to, swap the node.
	if def.node_repaired_name and minetest.registered_items[def.node_repaired_name] then
		minetest.swap_node(pos, {name = def.node_repaired_name, param1 = node.param1, param2 = node.param2})
	else
		--If it's not possible to repair this node, fail.
		return false
	end

	--If num was provided and it was more than 1...
	if num and num > 1 then
		--Call repair again, but with 1 less num.
		return node_damage.repair(pos, node, fixer, num - 1)
	end

	--Getting to the end of the function is only possible upon success.
	return true
end



--Register a tool that can test both the damage and repair functions.
minetest.register_tool("node_damage:test_hammer", {
	description = "Node Damage Test Hammer",
	inventory_image = "node_damage_test_hammer.png",

	--When left-clicking, 
	on_use = function(itemstack, user, pointed_thing)
		--If the user is pointing at a node,
		if pointed_thing.type == "node" then
			--Get the position of that node
			local pos = pointed_thing.under

			--Damage it once.
			node_damage.damage(pos, nil, user)
		end
	end,

	--When right-clicking,
	on_place = function(itemstack, placer, pointed_thing)
		--If the user is pointing at a node,
		if pointed_thing.type == "node" then
			--Get the position of that node
			local pos = pointed_thing.under

			--Repair it once.
			node_damage.repair(pos)
		end
	end
})



--If the tnt mod is being used...
if tnt then
	--Create a function that, after blasing a position, cracks nearby nodes.
	local function on_blast(pos, intensity)
		--Blast the position with a 3 node radius.
		tnt.boom(pos, {radius = minetest.settings:get("tnt_radius") or 3})

		--Cracking radius is set to a minimum of 5, but can be bigger if the explosion is more intense.
		local r = 5 * math.max(1, intensity)

		--In an 11x11x11 cube...
		for a = -r, r do
			for b = -r, r do
				for c = -r, r do
					--Get the current pos of the node to damage
					local npos = vector.add(pos, {x=a, y=b, z=c})
					--Get the distance between the current node and the center of the blast
					local dist = vector.distance(pos, npos)
					--Get the number of times to crack this node. Its random,
					--but the maximum increases when its closer to the center of the blast.
					local num = math.random(0, math.ceil(r / math.max(1, dist)))

					--If the distance of this node is within the radius of 5 (to create more of a spherical shape than a cube)
					--And the randomly selected num wasn't 0...
					if dist <= r and num > 0 then
						--Damage this particular node num times.
						node_damage.damage(npos, nil, nil, num)
					end
				end
			end
		end
	end

	--Override tnt blocks to use the above function when exploded.
	minetest.override_item("tnt:tnt", {
		on_blast = function(pos, intensity)
			minetest.after(0.1, on_blast, pos, intensity)
		end
	})

	--Override burning tnt blocks to use the above function once the timer runs out.
	minetest.override_item("tnt:tnt_burning", {
		on_timer = function(pos, elapsed)
			on_blast(pos, 1)
		end
	})
end
