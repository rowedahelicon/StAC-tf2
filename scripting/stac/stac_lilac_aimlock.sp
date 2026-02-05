#pragma semicolon 1

/*
    This code is modified from the source here: https://github.com/srcdslab/sm-plugin-lilac/blob/master/addons/sourcemod/scripting/lilac/lilac_aimlock.sp
*/

bool skip_due_to_loss(int client)
{
	/* Debate: What percentage should this be at?
	 * Skip detection if the loss is more than 50% */
	if (lilac_loss_fix.BoolValue)
		return GetClientAvgLoss(client, NetFlow_Both) > 0.5;

	return false;
}

void aim_at_point(const float p1[3], const float p2[3], float writeto[3])
{
	SubtractVectors(p2, p1, writeto);
	GetVectorAngles(writeto, writeto);

	while (writeto[0] > 90.0)
		writeto[0] -= 360.0;
	while (writeto[0] < -90.0)
		writeto[0] += 360.0;
	while (writeto[1] > 180.0)
		writeto[1] -= 360.0;
	while (writeto[1] < -180.0)
		writeto[1] += 360.0;

	writeto[2] = 0.0;
}


static bool aimlock_skip_player(int client)
{
	if (!is_player_valid(client)
		|| IsFakeClient(client)
		|| !IsPlayerAlive(client)
		|| GetClientTeam(client) < 2 /* Not on a valid team. */
		|| GetGameTime() - timeSinceTeleported[client] < 2.0 /* Player recently teleported. */
		|| skip_due_to_loss(client))
		//|| playerinfo_banned_flags[client][CHEAT_AIMLOCK]) /* Already banned/logged. */
		return true;

	/* Lightweight mode is enabled, don't process players who aren't in que. */
	if (lilac_aimlock_light.BoolValue && lilac_is_player_in_aimlock_que(client) == false)
		return true;

	return false;
}

void get_player_log_angles(int client, int tick, bool latest, float writeto[3])
{
	int i = tick;

	if (latest) {
		i = playerinfo_index[client];
	}
	else {
		while (i < 0)
			i += CMD_LENGTH;
		while (i >= CMD_LENGTH)
			i -= CMD_LENGTH;
	}

	writeto[0] = playerinfo_angles[client][i][0];
	writeto[1] = playerinfo_angles[client][i][1];
	writeto[2] = playerinfo_angles[client][i][2];
}


static bool aimlock_skip_target(int client, int target)
{
	return (client == target
		|| !is_player_valid(target)
		|| GetClientTeam(client) == GetClientTeam(target)
		|| !IsPlayerAlive(target)
		|| GetClientTeam(target) < 2 /* Target isn't in a valid team. */
		|| GetGameTime() - timeSinceTeleported[target] < 2.0); /* Teleported. */
}

float angle_delta(float []a1, float []a2)
{
	int normal = 5;
	float p1[3], p2[3], delta;

	p1[0] = a1[0];
	p2[0] = a2[0];
	p2[1] = a2[1];
	p1[1] = a1[1];

	/* We don't care about roll. */
	p1[2] = 0.0;
	p2[2] = 0.0;

	delta = GetVectorDistance(p1, p2);

	/* Normalize maximum 5 times, yaw can sometimes be odd. */
	while (delta > 180.0 && normal > 0) {
		normal--;
		delta = FloatAbs(delta - 360.0);
	}

	return delta;
}

public Action timer_check_aimlock(Handle timer)
{
	float pos[3], pos2[3];
	int players_processed = 0;
	bool detected_aimlock[MAXPLAYERS + 1];

	if (!lilac_aimlock.IntValue)
		return Plugin_Continue;

	for (int client = 1; client <= MaxClients; client++) {
		detected_aimlock[client] = false;

		/* Don't process more than 5 players.
		 * Note: Don't use a "break" statement here!
		 * We need to set detected_aimlock[...] to false
		 * on every single player!
		 * This will then also serve as a "is_player_valid()"
		 * for players who need to be detected for Aimlock. */
		if (lilac_aimlock_light.BoolValue && players_processed >= 5)
			continue;

		if (aimlock_skip_player(client))
			continue;

		GetClientEyePosition(client, pos);

		players_processed++;

		bool process = true;
		for (int target = 1; process && target <= MaxClients; target++) {
			if (aimlock_skip_target(client, target))
				continue;

			GetClientEyePosition(target, pos2);

			/* Too close to an enemy, don't report aimlock
			 * detections and stop processing this player. */
			if (GetVectorDistance(pos, pos2) < 300.0) {
				detected_aimlock[client] = false;
				process = false;
				continue;
			}

			/* Player has already been detected of using aimlock,
			 * don't check for aimlock again, only check
			 * if the player is too close to other enemies. */
			if (detected_aimlock[client])
				continue;

			if (is_aimlocking(client, pos, pos2))
				detected_aimlock[client] = true;
		}
	}

	for (int i = 1; i <= MaxClients; i++) {
		if (detected_aimlock[i])
			lilac_detected_aimlock(i);
	}

	return Plugin_Continue;
}

static bool is_aimlocking(int client, float pos[3], float pos2[3])
{
	float ideal[3], lang[3], ang[3];
	float laimdist, aimdist;
	int lock = 0;
	int ind;

	aim_at_point(pos, pos2, ideal);

	ind = playerinfo_index[client];
	for (int i = 0; i < time_to_ticks(0.5 + 0.1); i++) {
		if (ind < 0)
			ind += CMD_LENGTH;

		/* Only process aimlock time. */
		if (GetGameTime() - playerinfo_time_usercmd[client][ind] < 0.5 + 0.1) {
			get_player_log_angles(client, ind, false, ang);
			laimdist = angle_delta(ang, ideal);

			if (i) {
				if (aimdist < 5.0)
					lock++;
				else
					lock = 0;

				if (aimdist < laimdist * 0.1
					&& angle_delta(ang, lang) > 20.0
					&& lock > time_to_ticks(0.1))
					return true;
			}

			lang = ang;
			aimdist = laimdist;
		}

		ind--;
	}

	return false;
}

static void lilac_detected_aimlock(int client)
{
	// if (playerinfo_banned_flags[client][CHEAT_AIMLOCK])
	// 	return;

	/* Suspicions reset after 3 minutes.
	 * This means you need to get two aimlocks within
	 * three minutes of each other to get a single detection. */
	if (GetGameTime() - playerinfo_time_aimlock[client] < 180.0)
		playerinfo_aimlock_sus[client]++;
	else
		playerinfo_aimlock_sus[client] = 1;

	playerinfo_time_aimlock[client] = GetGameTime();

	if (playerinfo_aimlock_sus[client] < 2)
		return;

	playerinfo_aimlock_sus[client] = 0;

	// if (lilac_forward_allow_cheat_detection(client, CHEAT_AIMLOCK) == false)
	// 	return;

	/* Detection expires in 10 minutes. */
	CreateTimer(600.0, timer_decrement_aimlock, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

	char sDetails[512];
	Format(sDetails, sizeof(sDetails), "Detection: %d", playerinfo_aimlock[client]);

	// lilac_save_player_details(client, sDetails);
	// lilac_forward_client_cheat(client, CHEAT_AIMLOCK);

	/* Don't log the first detection. */
	if (++playerinfo_aimlock[client] < 2)
		return;

	int userid = GetClientUserId(client);

	char msg[256];
	Format(msg, sizeof(msg), "Player %N triggered aimlock detection", client);

	PrintToImportant("{hotpink}[StAC]{white} Player %N {mediumpurple}trigger aimlock detection{white}!\nConsecutive detections so far: {palegreen}%i" , client, playerinfo_aimlock[client]);
	StacNotify(userid, msg, playerinfo_aimlock[client]);
	StacLog("Player %N triggered aimlock detection", client);

	// if (icvar[CVAR_CHEAT_WARN])
	// 	lilac_warn_admins(client, CHEAT_AIMLOCK, playerinfo_aimlock[client]);

	// if (icvar[CVAR_LOG]) {
	// 	lilac_log_setup_client(client);
	// 	Format(line_buffer, sizeof(line_buffer),
	// 		"%s is suspected of using an aimlock (%s).",
	// 		line_buffer, sDetails);

	// 	lilac_log(true);

	// 	if (icvar[CVAR_LOG_EXTRA] == 2)
	// 		lilac_log_extra(client);
	// }
	// database_log(client, "aimlock", playerinfo_aimlock[client]);

	if (playerinfo_aimlock[client] >= lilac_aimlock.IntValue
	&& lilac_aimlock.IntValue >= 5) {
		aimlockBan(userid);
	}
	// 	playerinfo_banned_flags[client][CHEAT_AIMLOCK] = true;

		// if (icvar[CVAR_LOG]) {
		// 	lilac_log_setup_client(client);
		// 	Format(line_buffer, sizeof(line_buffer),
		// 		"%s was banned for Aimlock.", line_buffer);

		// 	lilac_log(true);

		// 	if (icvar[CVAR_LOG_EXTRA])
		// 		lilac_log_extra(client);
		// }
		// database_log(client, "aimlock", DATABASE_BAN);

		//lilac_ban_client(client, CHEAT_AIMLOCK);
	//}
}

void lilac_aimlock_light_test(int client)
{
	int ind;
	float lastang[3], ang[3];

	/* Player recently teleported, spawned or taunted. Ignore. */
	if (GetGameTime() - timeSinceTeleported[client] < 3.0)
		return;

	ind = playerinfo_index[client];
	for (int i = 0; i < time_to_ticks(0.5); i++) {
		if (ind < 0)
			ind += CMD_LENGTH;

		get_player_log_angles(client, ind, false, ang);

		if (i) {
			/* This player has a somewhat big delta,
			 * test this player for aimlock for 200 seconds.
			 * Even if we end up flagging more than 5 players
			 * for this, that's fine as only 5 players
			 * can be processed in the aimlock check timer. */
			if (angle_delta(lastang, ang) > 20.0) {
				playerinfo_time_process_aimlock[client] = GetGameTime() + 200.0;
				return;
			}
		}

		lastang = ang;
		ind--;
	}
}

void aimlockBan(int userid)
{
    int cl = GetClientOfUserId(userid);
    char reason[128];
    Format(reason, sizeof(reason), "[StAC] Banned for aimlock detections.");
    char pubreason[256];
    Format(pubreason, sizeof(pubreason), "{hotpink}[StAC]{white} Player %N had {mediumpurple}triggered aimlock detections{white}! {palegreen}BANNED from server!", cl);
    // we have to do extra bullshit here so we don't crash when banning clients out of this callback
    // make a pack
    DataPack pack = CreateDataPack();
    // prepare pack
    WritePackCell(pack, userid);
    WritePackString(pack, reason);
    WritePackString(pack, pubreason);
    ResetPack(pack, false);
    // make data timer
    CreateTimer(0.1, Timer_BanUser, pack, TIMER_DATA_HNDL_CLOSE);
    return;
}

static bool lilac_is_player_in_aimlock_que(int client)
{
	/* Test for aimlock on players who: */
	return (GetGameTime() < playerinfo_time_process_aimlock[client] /* Are in the que. */
		|| playerinfo_aimlock[client] /* Already has a detection. */
		//|| lilac_aimbot_get_client_detections(client) > 1 /* Already have been detected for aimbot twice. */
		|| GetClientTime(client) < 240.0 /* Client just joined the game. */
		|| (GetGameTime() - playerinfo_time_aimlock[client] < 180.0
			&& playerinfo_time_aimlock[client] > 1.0)); /* Had one aimlock the past three minutes. */
}

public Action timer_decrement_aimlock(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);

	if (!is_player_valid(client))
		return Plugin_Continue;

	if (playerinfo_aimlock[client] > 0)
		playerinfo_aimlock[client]--;

	return Plugin_Continue;
}