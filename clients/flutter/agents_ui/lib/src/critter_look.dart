// The mascot a folder wears.
//
// Every agent has the deck's critter, drawn in its tool's colours and wearing
// the hat its working folder picked. A folder can wear one of the pet shapes
// instead ([AgentHat.critter], picked beside the hat in the same place), and
// then that creature is drawn where the critter would be.
//
// Nothing here grows, eats or sleeps: the creature is a look, and it stays
// whichever one was picked. Agent pets, where a pet hatches from an egg and
// climbs levels on its agent's tokens, is a separate thing and is switched on
// in the service's own settings.

import 'package:flutter/widgets.dart';

import 'agents_model.dart';
import 'critter.dart';
import 'pet_art.dart';

/// How a chosen creature is drawn: the pet the art wants, standing still at
/// the stage that was picked.
AgentPet _petFor(String look) => switch (look) {
  // An egg cracks once its pet has eaten enough; a folder that picked the
  // cracked one is drawn past that mark and the whole one short of it.
  'egg' => const AgentPet(stage: 'egg', hearts: 4, mood: 'fed'),
  'cracked' => const AgentPet(stage: 'egg', ate: 40000, hearts: 4, mood: 'fed'),
  // A level the stage starts at, so the art draws it as its own shape rather
  // than as one on its way somewhere.
  'baby' => const AgentPet(stage: 'baby', level: 1, hearts: 4, mood: 'fed'),
  'kid' => const AgentPet(stage: 'kid', level: 5, hearts: 4, mood: 'fed'),
  'grown' => const AgentPet(stage: 'grown', level: 10, hearts: 4, mood: 'fed'),
  'strong' => const AgentPet(
    stage: 'strong',
    level: 20,
    hearts: 4,
    mood: 'fed',
  ),
  'mighty' => const AgentPet(
    stage: 'mighty',
    level: 30,
    hearts: 4,
    mood: 'fed',
  ),
  _ => const AgentPet(stage: 'legend', level: 40, hearts: 4, mood: 'fed'),
};

/// The mascot for [agent]: its creature where its folder picked one, else the
/// deck's critter. The arguments are the critter's, so a caller swaps nothing
/// but the call.
Widget agentMascot(
  Agent agent, {
  required CritterPose pose,
  required double width,
  required Color body,
  required Color cut,
  Color? bubbleColor,
  bool centerBody = false,
  bool showBubble = true,
  DateTime? celebrateUntil,
  CritterPose afterCelebrate = CritterPose.idle,
}) {
  final look = agent.hat?.critter ?? '';
  if (look.isEmpty) {
    return CritterSprite(
      pose: pose,
      celebrateUntil: celebrateUntil,
      afterCelebrate: afterCelebrate,
      species: critterSpeciesFor(agent.tool),
      hat: agent.hat,
      centerBody: centerBody,
      showBubble: showBubble,
      width: width,
      body: body,
      bubble: bubbleColor,
      cut: cut,
    );
  }
  return PetSprite(
    pet: _petFor(look),
    hat: agent.hat,
    pose: pose,
    bubble: showBubble,
    celebrateUntil: celebrateUntil,
    afterCelebrate: afterCelebrate,
    width: width,
    fit: true,
  );
}

/// The same creature with nothing behind it: for the row of choices in the
/// hat picker, where [look] is one of [critterLooks] and "" is the critter.
Widget critterLookSprite(
  String look, {
  required double width,
  required Color body,
  required Color cut,
  AgentHat? hat,
  String tool = 'claude',
}) {
  if (look.isEmpty) {
    return CritterSprite(
      pose: CritterPose.idle,
      species: critterSpeciesFor(tool),
      hat: hat,
      centerBody: true,
      showBubble: false,
      width: width,
      body: body,
      cut: cut,
    );
  }
  return PetSprite(
    pet: _petFor(look),
    hat: hat,
    bubble: false,
    width: width,
    fit: true,
  );
}
