part of '../main.dart';

class AddGroupMembersPage extends StatefulWidget {
  final String groupName;
  final List<FriendRequest> candidates;

  const AddGroupMembersPage({
    super.key,
    required this.groupName,
    required this.candidates,
  });

  @override
  State<AddGroupMembersPage> createState() => _AddGroupMembersPageState();
}

class _AddGroupMembersPageState extends State<AddGroupMembersPage> {
  final Set<String> selectedIds = {};

  void _toggle(String id, bool selected) {
    setState(() {
      if (selected) {
        selectedIds.add(id);
      } else {
        selectedIds.remove(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Zu "${widget.groupName}" hinzufügen')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  for (final request in widget.candidates)
                    InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => _toggle(
                        request.otherProfile.id,
                        !selectedIds.contains(request.otherProfile.id),
                      ),
                      child: _PersonTile(
                        profile: request.otherProfile,
                        trailing: Checkbox(
                          value: selectedIds.contains(request.otherProfile.id),
                          onChanged: (checked) =>
                              _toggle(request.otherProfile.id, checked == true),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: selectedIds.isEmpty
                      ? null
                      : () => Navigator.pop(context, selectedIds.toList()),
                  child: Text(
                    selectedIds.isEmpty
                        ? 'Hinzufügen'
                        : 'Hinzufügen (${selectedIds.length})',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows the group's timetable comparison: a dropdown to pick which member's
/// schedule is displayed, and a "Vergleichen" toggle that colors that
/// member's lessons/free periods based on how many other group members share
/// the same thing at that time (green = everyone, yellow = some).