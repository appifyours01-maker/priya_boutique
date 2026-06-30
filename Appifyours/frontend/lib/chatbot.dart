import 'package:flutter/material.dart';

import 'services/api_service.dart';
import 'services/gemini_service.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'main.dart';

class ChatBotPage extends StatefulWidget {
  final String shopName;
  final String appName;

  const ChatBotPage({
    super.key,
    required this.shopName,
    required this.appName,
  });

  @override
  State<ChatBotPage> createState() => _ChatBotPageState();
}

class _ChatBotPageState extends State<ChatBotPage> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _checkingPremium = false;
  bool _isPremium = true;
  bool _isLoadingData = true;
  bool _isSendingMessage = false;

  final List<_ChatMessage> _messages = <_ChatMessage>[];
  final GeminiService _geminiService = GeminiService();

  List<Map<String, dynamic>> _products = [];
  Map<String, dynamic> _storeInfo = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    bool premium = false;
    try {
      premium = await ApiService().hasActiveSubscription();
    } catch (_) {
      premium = false;
    }

    if (!mounted) return;

    setState(() {
      _isPremium = premium;
      _checkingPremium = false;
    });

    // Load product data
    await _loadProductData();

    if (!mounted) return;

    setState(() {
      _messages.add(
        _ChatMessage.bot(
          "Hi! I'm your ${widget.shopName} assistant. I can help you with product information, stock availability, pricing, and store details. How can I help you today?",
        ),
      );
    });

    _scrollToBottom();
  }

  Future<void> _loadProductData() async {
    try {
      setState(() => _isLoadingData = true);

      // Fetch product data from backend using same API as main.dart
      final adminId = await AdminManager.getCurrentAdminId();
      print('🔍 Chatbot using admin ID: ${adminId}');
      print('🌐 API URL: ${ApiConfig.baseUrl}/api/get-form?adminId=${adminId}&appId=${ApiConfig.appId}');

      final response = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/api/get-form?adminId=$adminId&appId=${ApiConfig.appId}'),
        headers: {'Content-Type': 'application/json'},
      );

      print('📡 Response status: ${response.statusCode}');

      Map<String, dynamic> businessDetails = {};
      List<Map<String, dynamic>> extractedProducts = [];
      Map<String, dynamic> storeInfoData = {};

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        print('📦 Response data: ${data.toString().substring(0, data.toString().length > 500 ? 500 : data.toString().length)}...');
        
        if (data['success'] == true) {
          final pages = (data['pages'] is List) ? List.from(data['pages']) : <dynamic>[];

          // Extract products from widgets
          if (pages.isNotEmpty && pages.first is Map && (pages.first as Map)['widgets'] is List) {
            final widgets = List<Map<String, dynamic>>.from((pages.first as Map)['widgets']);
            for (final w in widgets) {
              final name = (w['name'] ?? '').toString();
              final props = w['properties'];
              
              // Extract products
              if (name == 'ProductGridWidget' || name == 'Catalog View Card' || name == 'Product Detail Card') {
                if (props is Map && props['productCards'] is List) {
                  extractedProducts.addAll(List<Map<String, dynamic>>.from(props['productCards']));
                }
              }
              
              // Extract store info from StoreInfoWidget properties (like main.dart does)
              if (name == 'StoreInfoWidget' && props is Map) {
                if (props['storeName'] != null) storeInfoData['storeName'] = props['storeName'];
                if (props['address'] != null) storeInfoData['address'] = props['address'];
                if (props['email'] != null) storeInfoData['email'] = props['email'];
                if (props['phone'] != null) storeInfoData['phone'] = props['phone'];
                if (props['website'] != null) storeInfoData['website'] = props['website'];
                print('📋 Found store info in StoreInfoWidget: $storeInfoData');
              }
            }
          }

          // Extract store info from API response - same as main.dart
          final apiStoreInfo = (data['storeInfo'] is Map) 
              ? Map<String, dynamic>.from(data['storeInfo']) 
              : <String, dynamic>{};
          
          // Merge widget store info with API store info (widget takes priority like main.dart)
          if (storeInfoData.isNotEmpty) {
            // Widget properties found, use them
            print('✅ Using store info from widget properties');
          } else if (apiStoreInfo.isNotEmpty) {
            // Use API storeInfo if no widget properties found
            storeInfoData = apiStoreInfo;
            print('✅ Using store info from API storeInfo field');
          } else {
            // Fallback to top-level fields
            storeInfoData = {
              'storeName': data['shopName'] ?? data['appName'],
              'shopName': data['shopName'] ?? data['appName'],
              'appName': data['appName'],
            };
            print('⚠️ storeInfo field not found in API response, using top-level fields');
          }
          
          print('✅ Final store info: $storeInfoData');
          print('🔍 Available API fields: ${data.keys.toList()}');
        } else {
          print('❌ API returned success: false');
        }
      } else {
        print('❌ HTTP error: ${response.statusCode}');
        print('Response body: ${response.body}');
      }

      // Fetch business details separately
      try {
        final apiService = ApiService();
        businessDetails = await apiService.getBusinessDetails() ?? {};
        print('✅ Business details: $businessDetails');
      } catch (e) {
        print('Error fetching business details: $e');
      }

      if (mounted) {
        setState(() {
          _products = extractedProducts;
          _storeInfo = storeInfoData;
          _isLoadingData = false;
        });

        // Update Gemini service with all data
        _geminiService.updateProducts(_products);
        _geminiService.updateStoreInfo(_storeInfo);
        _geminiService.updateBusinessDetails(businessDetails);
        
        print('Loaded ${_products.length} products for chatbot');
        print('Store info: $_storeInfo');
        print('Business details: $businessDetails');
      }
    } catch (e) {
      print('Error loading product data: $e');
      if (mounted) {
        setState(() => _isLoadingData = false);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  void _send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _isSendingMessage) return;

    setState(() {
      _messages.add(_ChatMessage.user(trimmed));
      _isSendingMessage = true;
    });
    _controller.clear();
    _scrollToBottom();

    try {
      // Get response from Gemini AI
      final reply = await _geminiService.sendMessage(trimmed);
      
      if (!mounted) return;
      
      setState(() {
        _messages.add(_ChatMessage.bot(reply));
        _isSendingMessage = false;
      });
      _scrollToBottom();
    } catch (e) {
      print('Error getting AI response: $e');
      if (!mounted) return;
      
      setState(() {
        _messages.add(_ChatMessage.bot(
          'I apologize, but I encountered an error. Please try again.'
        ));
        _isSendingMessage = false;
      });
      _scrollToBottom();
    }
  }

  List<String> get _quickReplies => <String>[
        'How many products do you have?',
        'What products are available?',
        'Check stock availability',
        'Tell me about your store',
      ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.shopName} Support'),
      ),
      body: _isLoadingData
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Loading product data...'),
                ],
              ),
            )
          : _buildChat(context),
    );
  }

  Widget _buildPremiumRequired(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          const Icon(Icons.lock_outline, size: 56),
          const SizedBox(height: 16),
          const Text(
            'Chatbot is a Premium feature',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'Upgrade your plan to enable chatbot for ${widget.shopName}.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildChat(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            itemCount: _messages.length + (_isSendingMessage ? 1 : 0),
            itemBuilder: (context, index) {
              // Show typing indicator when sending message
              if (index == _messages.length && _isSendingMessage) {
                return Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.78,
                    ),
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Thinking...',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }

              final m = _messages[index];
              return Align(
                alignment: m.isUser ? Alignment.centerRight : Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.78,
                  ),
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: m.isUser
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      m.text,
                      style: TextStyle(
                        color: m.isUser
                            ? Theme.of(context).colorScheme.onPrimary
                            : Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _quickReplies
                  .map(
                    (q) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        label: Text(q),
                        onPressed: () => _send(q),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textInputAction: TextInputAction.send,
                    onSubmitted: _isSendingMessage ? null : _send,
                    enabled: !_isSendingMessage,
                    decoration: const InputDecoration(
                      hintText: 'Type a message…',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _isSendingMessage ? null : () => _send(_controller.text),
                  icon: _isSendingMessage 
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ChatMessage {
  final bool isUser;
  final String text;

  const _ChatMessage._(this.isUser, this.text);

  factory _ChatMessage.user(String text) => _ChatMessage._(true, text);
  factory _ChatMessage.bot(String text) => _ChatMessage._(false, text);
}
