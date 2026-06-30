// ================================================================
// DELIVERY FEATURE — SHIPROCKET BACKEND PROXY (Production-Ready)
// ================================================================
//
// This version routes all Shiprocket API calls through the backend
// to avoid CORS errors on Flutter Web and improve security.
//
// Backend endpoints:
//   - POST /api/shiprocket/check-pincode
//   - POST /api/shiprocket/courier-rates
//   - POST /api/shiprocket/create-order
//   - GET /api/shiprocket/track/:awbCode
//
// ================================================================

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:io';
import 'package:appifyours/services/api_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

// ================================================================
// ⚙️  CONFIG — Backend proxy URL
// ================================================================
class ShiprocketConfig {
  static String get baseUrl {
    final configured = dotenv.env['API_BASE']?.trim() ?? '';
    if (configured.isEmpty) {
      throw Exception(
        'API_BASE environment variable is not set. '
        'Please configure it in your .env file.'
      );
    }
    return configured;
  }
  
  static const String pickupLocation = 'home';
  static const String pickupPincode = '600124';
}

// ================================================================
// 1. SHIPROCKET SERVICE (Backend Proxy)
// ================================================================
class ShiprocketService {
  final ApiService _apiService = ApiService();

  // Helper to get token from ApiService
  Future<String?> _getToken() async {
    // Use the public method if available, or access directly
    try {
      // Try to use a public method first
      return await _apiService.getToken();
    } catch (e) {
      // Fallback: directly access shared preferences
      try {
        final prefs = await SharedPreferences.getInstance();
        return prefs.getString('auth_token');
      } catch (e2) {
        print('Error getting token: $e2');
        return null;
      }
    }
  }

  // Helper to make authenticated requests to backend proxy
  Future<Map<String, dynamic>> _proxyRequest(
    String method,
    String endpoint,
    Map<String, dynamic>? body,
  ) async {
    try {
      final token = await _getToken();
      if (token == null) {
        throw Exception('No authentication token found');
      }

      final url = Uri.parse('${ShiprocketConfig.baseUrl}/api/shiprocket$endpoint');
      debugPrint('📤 SR Proxy: $method $url');

      late http.Response response;
      final timeout = const Duration(seconds: 30);
          
      if (method == 'POST') {
        response = await http.post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: json.encode(body),
        ).timeout(timeout);
      } else if (method == 'GET') {
        response = await http.get(
          url,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
        ).timeout(timeout);
      } else {
        throw Exception('Unsupported method: $method');
      }

      debugPrint('📥 SR Proxy Response: ${response.statusCode}');
      
      final data = json.decode(response.body);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return _convertResponseToStrings(data);
      } else {
        throw Exception(data['error']?.toString() ?? 'Request failed');
      }
    } catch (e) {
      debugPrint('❌ SR Proxy error: $e');
      rethrow;
    }
  }

  Map<String, dynamic> _convertResponseToStrings(Map<String, dynamic> data) {
    final converted = <String, dynamic>{};
    data.forEach((key, value) {
      if (value is int || value is double) {
        converted[key] = value.toString();
      } else if (value is Map) {
        converted[key] = _convertResponseToStrings(value as Map<String, dynamic>);
      } else if (value is List) {
        converted[key] = value.map((item) {
          if (item is Map) {
            return _convertResponseToStrings(item as Map<String, dynamic>);
          } else if (item is int || item is double) {
            return item.toString();
          }
          return item;
        }).toList();
      } else {
        converted[key] = value;
      }
    });
    return converted;
  }

  // ── CHECK PINCODE ────────────────────────────────────────────
  Future<PincodeResult> checkPincode(String pincode) async {
    debugPrint('📍 SR: Checking pincode: $pincode');

    try {
      final result = await _proxyRequest('POST', '/check-pincode', {'pincode': pincode});
      
      return PincodeResult(
        serviceable: result['serviceable'] ?? false,
        city: result['city'] ?? '',
        state: result['state'] ?? '',
        message: result['message'],
      );
    } catch (e) {
      debugPrint('❌ SR: Pincode check failed: $e');
      return PincodeResult(
        serviceable: false,
        city: '',
        state: '',
        message: 'Pincode validation failed',
      );
    }
  }

  // ── GET COURIER RATES ────────────────────────────────────────
  Future<List<CourierOption>> getCourierRates({
    required String pincode,
    required double orderValue,
  }) async {
    debugPrint('🚚 SR: Fetching courier rates for pincode: $pincode, order value: $orderValue');

    try {
      final result = await _proxyRequest('POST', '/courier-rates', {
        'pincode': pincode,
        'orderValue': orderValue,
      });
      
      if (result['success'] == true && result['couriers'] != null) {
        final List<dynamic> couriers = result['couriers'];
        return couriers.map((c) => CourierOption(
          courierId: c['courierId']?.toString() ?? '',
          courierName: c['courierName']?.toString() ?? 'Standard',
          rate: (c['rate'] as num?)?.toDouble() ?? 49.0,
          estimatedDays: c['estimatedDays']?.toString() ?? '3-5',
          codAvailable: c['codAvailable'] == true,
        )).toList();
      }
    } catch (e) {
      debugPrint('❌ SR: Courier rates fetch failed: $e');
    }
    
    debugPrint('⚠️ SR: Returning default couriers as fallback');
    return _defaultCouriers();
  }

  List<CourierOption> _defaultCouriers() => [
        CourierOption(courierId: '1', courierName: 'Delhivery', rate: 49, estimatedDays: '3-5', codAvailable: true),
        CourierOption(courierId: '2', courierName: 'Ekart', rate: 39, estimatedDays: '4-6', codAvailable: true),
        CourierOption(courierId: '3', courierName: 'XpressBees', rate: 55, estimatedDays: '2-4', codAvailable: false),
      ];

  // ── PLACE ORDER ─────────────────────────────────────────────
  Future<OrderResult> placeOrder({
    required DeliveryAddress address,
    required List<Map<String, dynamic>> items,
    required double totalAmount,
    required CourierOption courier,
    required String timeSlot,
    required String paymentMethod,
  }) async {
    debugPrint('📦 SR: Placing order for ${address.fullName} at ${address.pincode}');

    final localId = 'ORD${DateTime.now().millisecondsSinceEpoch}';
    
    // Build order items
    final orderItems = <Map<String, dynamic>>[];
    for (var idx = 0; idx < items.length; idx++) {
      final i = items[idx];
      if (i == null) {
        debugPrint('⚠️ SR: Skipping null item at index $idx');
        continue;
      }
      final price = (i['price'] is num ? (i['price'] as num).toDouble() : 0.0);
      final qty = (i['quantity'] is num ? (i['quantity'] as num).toInt() : 1);
      final itemName = (i['name']?.toString() ?? 'Product');
      final itemId = (i['id']?.toString() ?? 'SKU${idx + 1}');
      final sku = itemId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      
      orderItems.add({
        'name': itemName,
        'sku': sku,
        'units': qty.toString(),
        'selling_price': price.toStringAsFixed(2),
        'discount': '',
        'tax': '',
        'hsn': '',
      });
      debugPrint('  📦 SR: Item $idx: $itemName (SKU: $sku, Qty: $qty, Price: $price)');
    }

    if (orderItems.isEmpty) {
      debugPrint('❌ SR: No valid items in order');
      return OrderResult(
        success: false,
        orderId: localId,
        message: 'No valid items in order',
      );
    }

    try {
      final result = await _proxyRequest('POST', '/create-order', {
        'address': {
          'fullName': address.fullName,
          'addressLine1': address.addressLine1,
          'addressLine2': address.addressLine2,
          'city': address.city,
          'pincode': address.pincode,
          'state': address.state,
          'email': address.email,
          'phone': address.phone,
        },
        'items': orderItems,
        'totalAmount': totalAmount,
        'courier': {
          'courierId': courier.courierId,
          'courierName': courier.courierName,
          'rate': courier.rate.toString(),
        },
        'timeSlot': timeSlot,
        'paymentMethod': paymentMethod,
        'shopName': 'Appifyours',
      });
      
      if (result['success'] == true) {
        debugPrint('✅ SR: Order created successfully via backend proxy');
        
        return OrderResult(
          success: true,
          orderId: result['orderId']?.toString() ?? localId,
          shipmentId: result['shipmentId']?.toString() ?? '',
          awbCode: result['awbCode']?.toString() ?? '',
          message: result['message']?.toString() ?? 'Order placed on Shiprocket ✅',
        );
      } else {
        throw Exception(result['error']?.toString() ?? 'Order creation failed');
      }
    } catch (e) {
      debugPrint('❌ SR: Order creation failed: $e');
      return OrderResult(
        success: false,
        orderId: localId,
        message: 'Network error: ${e.toString()}',
      );
    }
  }

  // ── TRACK ORDER ──────────────────────────────────────────────
  Future<TrackingResult> trackOrder(String awbCode) async {
    debugPrint('📍 SR: Tracking order for AWB: $awbCode');
    
    if (awbCode.isEmpty) {
      debugPrint('⚠️ SR: No AWB code provided, returning demo tracking');
      return _demoTracking();
    }

    try {
      final result = await _proxyRequest('GET', '/track/$awbCode', null);
      
      if (result['success'] == true) {
        final List<dynamic> events = result['events'] ?? [];
        return TrackingResult(
          status: result['status'] ?? 'Processing',
          currentLocation: result['currentLocation'] ?? '',
          estimatedDate: result['estimatedDate'] ?? '',
          events: events.map((e) => TrackEvent(
            status: e['status']?.toString() ?? '',
            location: e['location']?.toString() ?? '',
            time: e['time']?.toString() ?? '',
            done: e['done'] == true,
          )).toList(),
        );
      }
    } catch (e) {
      debugPrint('❌ SR: Tracking failed: $e');
    }

    return _demoTracking();
  }

  TrackingResult _demoTracking() => TrackingResult(
        status: 'Order Placed',
        currentLocation: 'Seller Warehouse',
        estimatedDate: '3-5 days',
        events: [
          TrackEvent(status: 'Order Placed', location: 'Seller Warehouse', time: _ago(1), done: true),
          TrackEvent(status: 'Picked Up', location: 'Seller Warehouse', time: '', done: false),
          TrackEvent(status: 'In Transit', location: '', time: '', done: false),
          TrackEvent(status: 'Out for Delivery', location: '', time: '', done: false),
          TrackEvent(status: 'Delivered', location: '', time: '', done: false),
        ],
      );

  String _ago(int h) {
    final dt = DateTime.now().subtract(Duration(hours: h));
    return '${dt.day}/${dt.month}/${dt.year} ${_pad(dt.hour)}:${_pad(dt.minute)}';
  }

  String _pad(int n) => n.toString().padLeft(2, '0');
}

// ================================================================
// 2. DATA MODELS
// ================================================================

class PincodeResult {
  final bool serviceable;
  final String city, state;
  final String? message;
  PincodeResult({required this.serviceable, this.city = '', this.state = '', this.message});
}

class CourierOption {
  final String courierId, courierName, estimatedDays;
  final double rate;
  final bool codAvailable;
  CourierOption({
    required this.courierId,
    required this.courierName,
    required this.rate,
    required this.estimatedDays,
    this.codAvailable = true,
  });
}

class DeliveryAddress {
  final String fullName, phone, pincode, addressLine1, addressLine2, city, state, email;
  DeliveryAddress({
    required this.fullName,
    required this.phone,
    required this.pincode,
    required this.addressLine1,
    this.addressLine2 = '',
    required this.city,
    required this.state,
    this.email = '',
  });
}

class OrderResult {
  final bool success;
  final String orderId, awbCode, shipmentId, message;
  OrderResult({
    required this.success,
    required this.orderId,
    this.awbCode = '',
    this.shipmentId = '',
    this.message = '',
  });
}

class TrackingResult {
  final String status, currentLocation, estimatedDate;
  final List<TrackEvent> events;
  TrackingResult({required this.status, this.currentLocation = '', this.estimatedDate = '', required this.events});
}

class TrackEvent {
  final String status, location, time;
  final bool done;
  TrackEvent({required this.status, required this.location, required this.time, required this.done});
}

class TimeSlot {
  final String id, label, timeRange;
  TimeSlot({required this.id, required this.label, required this.timeRange});
}

// ================================================================
// 3. DELIVERY CHECKOUT PAGE
// ================================================================
class DeliveryCheckoutPage extends StatefulWidget {
  final dynamic cartManager;
  const DeliveryCheckoutPage({super.key, required this.cartManager});
  @override
  State<DeliveryCheckoutPage> createState() => _DCPState();
}

class _DCPState extends State<DeliveryCheckoutPage> {
  int _step = 0;

  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  final _a1Ctrl = TextEditingController();
  final _a2Ctrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _stCtrl = TextEditingController();

  bool _checkingPin = false, _pinOk = false;
  String? _pinError;

  List<CourierOption> _couriers = [];
  CourierOption? _selCourier;
  bool _loadingC = false;

  final _slots = [
    TimeSlot(id: 's1', label: '🌅 Morning', timeRange: '9:00 AM – 12:00 PM'),
    TimeSlot(id: 's2', label: '☀️ Afternoon', timeRange: '12:00 PM – 3:00 PM'),
    TimeSlot(id: 's3', label: '🌆 Evening', timeRange: '3:00 PM – 6:00 PM'),
    TimeSlot(id: 's4', label: '🌙 Night', timeRange: '6:00 PM – 9:00 PM'),
  ];
  TimeSlot? _selSlot;
  DateTime _selDate = DateTime.now().add(const Duration(days: 1));
  String _pay = 'prepaid';
  bool _placing = false;

  final _svc = ShiprocketService();

  String get _currency {
    try {
      final sym = widget.cartManager.displayCurrencySymbol;
      if (sym is String && sym.isNotEmpty) return sym;
    } catch (_) {}
    try {
      final first = _items.isNotEmpty ? _items.first : null;
      final sym = first?.currencySymbol;
      if (sym is String && sym.isNotEmpty) return sym;
    } catch (_) {}
    return '₹';
  }

  double get _subtotal {
    try {
      return (widget.cartManager.subtotal as num).toDouble();
    } catch (_) {
      return _cartTotal;
    }
  }

  double get _gstAmount {
    try {
      return (widget.cartManager.gstAmount as num).toDouble();
    } catch (_) {
      return (_cartTotal - _subtotal);
    }
  }

  double get _discountAmount {
    try {
      return (widget.cartManager.totalDiscount as num).toDouble();
    } catch (_) {
      return 0.0;
    }
  }

  double get _cartTotal {
    try {
      return (widget.cartManager.finalTotal as num).toDouble();
    } catch (_) {
      return 0.0;
    }
  }

  double get _shipping => _selCourier?.rate ?? 0.0;
  double get _grand => _cartTotal + _shipping;
  List get _items {
    try {
      return widget.cartManager.items as List;
    } catch (_) {
      return [];
    }
  }

  @override
  void dispose() {
    for (final c in [_nameCtrl, _phoneCtrl, _emailCtrl, _pinCtrl, _a1Ctrl, _a2Ctrl, _cityCtrl, _stCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _checkPin(String pin) async {
    if (pin.length != 6) {
      setState(() {
        _pinOk = false;
        _pinError = null;
        _couriers = [];
        _selCourier = null;
      });
      return;
    }
    setState(() {
      _checkingPin = true;
      _pinError = null;
      _pinOk = false;
    });
    final r = await _svc.checkPincode(pin);
    if (!mounted) return;
    if (r.serviceable) {
      if (r.city.isNotEmpty) _cityCtrl.text = r.city;
      if (r.state.isNotEmpty) _stCtrl.text = r.state;
      setState(() {
        _pinOk = true;
        _checkingPin = false;
      });
    } else {
      setState(() {
        _pinOk = false;
        _pinError = r.message ?? 'Delivery not available';
        _checkingPin = false;
      });
    }
  }

  Future<void> _loadCouriers() async {
    setState(() {
      _loadingC = true;
    });
    final list = await _svc.getCourierRates(pincode: _pinCtrl.text.trim(), orderValue: _cartTotal);
    if (!mounted) return;
    setState(() {
      _couriers = list;
      _selCourier = list.isNotEmpty ? list.first : null;
      _loadingC = false;
    });
  }

  bool _validateAddr() {
    if (_nameCtrl.text.trim().isEmpty) {
      _snack('Enter your full name');
      return false;
    }
    if (_phoneCtrl.text.trim().length != 10) {
      _snack('Enter valid 10-digit phone');
      return false;
    }
    if (!_pinOk) {
      _snack('Enter a valid serviceable pincode');
      return false;
    }
    if (_a1Ctrl.text.trim().isEmpty) {
      _snack('Enter your address');
      return false;
    }
    if (_cityCtrl.text.trim().isEmpty) {
      _snack('Enter city');
      return false;
    }
    if (_stCtrl.text.trim().isEmpty) {
      _snack('Enter state');
      return false;
    }
    return true;
  }

  Future<void> _placeOrder() async {
    if (_selSlot == null) {
      _snack('Select a time slot');
      return;
    }
    if (_selCourier == null) {
      _snack('Select a courier');
      return;
    }
    if (_pay == 'cod' && !_selCourier!.codAvailable) {
      _snack('COD not available for selected courier');
      return;
    }

    setState(() {
      _placing = true;
    });

    final addr = DeliveryAddress(
      fullName: _nameCtrl.text.trim(),
      phone: _phoneCtrl.text.trim(),
      email: _emailCtrl.text.trim(),
      pincode: _pinCtrl.text.trim(),
      addressLine1: _a1Ctrl.text.trim(),
      addressLine2: _a2Ctrl.text.trim(),
      city: _cityCtrl.text.trim(),
      state: _stCtrl.text.trim(),
    );

    final orderItems = _items
        .map((i) => {
              'id': (i.id is int ? i.id.toString() : i.id?.toString() ?? ''),
              'name': (i.name is String ? i.name : i.name?.toString() ?? ''),
              'price': (i.effectivePrice is num ? (i.effectivePrice as num).toDouble() : 0.0),
              'quantity': (i.quantity is num ? (i.quantity as num).toInt() : 1),
            })
        .toList();

    final result = await _svc.placeOrder(
      address: addr,
      items: orderItems,
      totalAmount: _grand,
      courier: _selCourier!,
      timeSlot: '${_selSlot!.label} • ${_selSlot!.timeRange}',
      paymentMethod: _pay,
    );

    if (!mounted) return;
    setState(() {
      _placing = false;
    });

    if (result.success) {
      try {
        final api = ApiService();
        await api.saveOrder({
          'items': orderItems,
          'totalAmount': _grand,
          'currency': _currency,
          'status': 'placed',
          'shippingAddress': {
            'fullName': addr.fullName,
            'phone': addr.phone,
            'email': addr.email,
            'pincode': addr.pincode,
            'addressLine1': addr.addressLine1,
            'addressLine2': addr.addressLine2,
            'city': addr.city,
            'state': addr.state,
          },
          'meta': {
            'timeSlot': '${_selSlot!.label} • ${_selSlot!.timeRange}',
            'paymentMethod': _pay,
            'shiprocketOrderId': result.orderId,
            'shipmentId': result.shipmentId,
          }
        });
      } catch (_) {
        // Saving order history should not block the checkout success flow
      }
      try {
        widget.cartManager.clearCart();
      } catch (_) {}
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => OrderSuccessPage(
            result: result,
            address: addr,
            courier: _selCourier!,
            slot: _selSlot!,
            grandTotal: _grand,
            paymentMethod: _pay,
            service: _svc,
          ),
        ),
      );
    } else {
      _snack('Order failed: ${result.message}');
      debugPrint('❌ Order failed: ${result.message}');
    }
  }

  void _snack(String m, {Color color = Colors.red}) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), backgroundColor: color, duration: const Duration(seconds: 5)),
      );

  Future<void> _onNext() async {
    if (_step == 0) {
      if (!_validateAddr()) return;
      await _loadCouriers();
      setState(() {
        _step = 1;
      });
    } else if (_step == 1) {
      if (_selSlot == null) {
        _snack('Select a time slot');
        return;
      }
      if (_selCourier == null) {
        _snack('Select a courier');
        return;
      }
      setState(() {
        _step = 2;
      });
    } else {
      await _placeOrder();
    }
  }

  // ── BUILD ───────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFFF5F7FA),
        appBar: AppBar(
          title: const Text('Checkout'),
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        body: Column(children: [
          _stepper(),
          Expanded(
              child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              child: _step == 0
                  ? _addrStep()
                  : _step == 1
                      ? _slotStep()
                      : _payStep(),
            ),
          )),
          _bottomBar(),
        ]),
      );

  // ── STEPPER ─────────────────────────────────────────────────
  Widget _stepper() {
    final labels = ['Address', 'Delivery', 'Payment'];
    return Container(
      color: Colors.blue,
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
      child: Row(
          children: List.generate(5, (i) {
        if (i.isOdd) {
          return Expanded(
              child: Container(
            height: 2,
            color: i ~/ 2 < _step ? Colors.white : Colors.white24,
          ));
        }
        final idx = i ~/ 2;
        final done = idx < _step;
        final active = idx == _step;
        return Column(children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: (done || active) ? Colors.white : Colors.white24,
            child: done
                ? const Icon(Icons.check, size: 14, color: Colors.blue)
                : Text('${idx + 1}',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: active ? Colors.blue : Colors.white54)),
          ),
          const SizedBox(height: 3),
          Text(labels[idx],
              style: TextStyle(
                fontSize: 10,
                color: active ? Colors.white : Colors.white54,
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
              )),
        ]);
      })),
    );
  }

  // ── STEP 0 — ADDRESS ────────────────────────────────────────
  Widget _addrStep() => Column(
        key: const ValueKey(0),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _card('📦 Order Summary', _orderSummary()),
          const SizedBox(height: 14),
          _card(
              '📍 Delivery Address',
              Column(children: [
                _tf(_nameCtrl, 'Full Name *', Icons.person, TextInputType.name),
                const SizedBox(height: 12),
                _tf(_phoneCtrl, 'Phone Number *', Icons.phone, TextInputType.phone, max: 10),
                const SizedBox(height: 12),
                _tf(_emailCtrl, 'Email (optional)', Icons.email, TextInputType.emailAddress),
                const SizedBox(height: 12),
                TextField(
                  controller: _pinCtrl,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  onChanged: _checkPin,
                  decoration: InputDecoration(
                    labelText: 'Pincode *',
                    prefixIcon: const Icon(Icons.location_pin),
                    counterText: '',
                    errorText: _pinError,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    filled: true,
                    fillColor: Colors.white,
                    suffixIcon: _checkingPin
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                        : _pinOk
                            ? const Icon(Icons.check_circle, color: Colors.green)
                            : null,
                  ),
                ),
                if (_pinOk) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.green.shade300),
                    ),
                    child: const Row(children: [
                      Icon(Icons.local_shipping, color: Colors.green, size: 15),
                      SizedBox(width: 8),
                      Text('✓  Delivery available at this pincode', style: TextStyle(fontSize: 12, color: Colors.green)),
                    ]),
                  ),
                ],
                const SizedBox(height: 12),
                _tf(_a1Ctrl, 'Address Line 1 *', Icons.home, TextInputType.streetAddress),
                const SizedBox(height: 12),
                _tf(_a2Ctrl, 'Address Line 2 (Optional)', Icons.apartment, TextInputType.streetAddress),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: _tf(_cityCtrl, 'City *', Icons.location_city, TextInputType.text)),
                  const SizedBox(width: 10),
                  Expanded(child: _tf(_stCtrl, 'State *', Icons.map, TextInputType.text)),
                ]),
              ])),
        ],
      );

  // ── STEP 1 — DATE / SLOT / COURIER ──────────────────────────
  Widget _slotStep() {
    const months = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    const wdays = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return Column(key: const ValueKey(1), crossAxisAlignment: CrossAxisAlignment.start, children: [
      _card(
          '📅 Delivery Date',
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
                children: List.generate(6, (i) {
              final dt = DateTime.now().add(Duration(days: i + 1));
              final sel = _selDate.day == dt.day && _selDate.month == dt.month;
              return GestureDetector(
                onTap: () => setState(() => _selDate = dt),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: const EdgeInsets.only(right: 10),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  decoration: BoxDecoration(
                    color: sel ? Colors.blue : Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: sel ? Colors.blue : Colors.grey.shade300),
                    boxShadow: sel
                        ? [BoxShadow(color: Colors.blue.withOpacity(0.4), blurRadius: 6, offset: const Offset(0, 2))]
                        : [],
                  ),
                  child: Column(children: [
                    Text(wdays[dt.weekday], style: TextStyle(fontSize: 11, color: sel ? Colors.white70 : Colors.grey)),
                    Text('${dt.day}',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold, color: sel ? Colors.white : Colors.black)),
                    Text(months[dt.month], style: TextStyle(fontSize: 11, color: sel ? Colors.white70 : Colors.grey)),
                  ]),
                ),
              );
            })),
          )),
      const SizedBox(height: 14),
      _card(
        '🕐 Time Slot',
        Column(
          children: _slots.map((s) {
            final sel = _selSlot?.id == s.id;
            return GestureDetector(
              onTap: () => setState(() => _selSlot = s),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: sel ? Colors.blue.shade50 : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: sel ? Colors.blue : Colors.grey.shade300, width: sel ? 2 : 1),
                ),
                child: Row(children: [
                  Radio<String>(
                    value: s.id,
                    groupValue: _selSlot?.id,
                    onChanged: (_) => setState(() => _selSlot = s),
                    activeColor: Colors.blue,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    Text(s.timeRange, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  ])),
                  if (sel) const Icon(Icons.check_circle, color: Colors.blue, size: 20),
                ]),
              ),
            );
          }).toList(),
        ),
      ),
      const SizedBox(height: 14),
      _card(
        '🚚 Shipping Options',
        _loadingC
            ? const Center(
                child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Column(children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 8),
                      Text('Fetching shipping rates...', style: TextStyle(color: Colors.grey)),
                    ])))
            : _couriers.isEmpty
                ? Container(
                    padding: const EdgeInsets.all(16),
                    child: const Text('No couriers available. Check pincode.', style: TextStyle(color: Colors.grey)),
                  )
                : Column(
                    children: _couriers.map((c) {
                    final sel = _selCourier?.courierId == c.courierId;
                    return GestureDetector(
                      onTap: () => setState(() => _selCourier = c),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: sel ? Colors.blue.shade50 : Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: sel ? Colors.blue : Colors.grey.shade300, width: sel ? 2 : 1),
                        ),
                        child: Row(children: [
                          Radio<String>(
                            value: c.courierId,
                            groupValue: _selCourier?.courierId,
                            onChanged: (_) => setState(() => _selCourier = c),
                            activeColor: Colors.blue,
                          ),
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(color: Colors.blue.shade50, borderRadius: BorderRadius.circular(8)),
                            child: const Icon(Icons.local_shipping, color: Colors.blue, size: 22),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(c.courierName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                            Row(children: [
                              Text('Est. ${c.estimatedDays} days', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                              if (c.codAvailable) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(color: Colors.orange.shade100, borderRadius: BorderRadius.circular(4)),
                                  child: const Text('COD',
                                      style: TextStyle(fontSize: 10, color: Colors.orange, fontWeight: FontWeight.bold)),
                                ),
                              ],
                            ]),
                          ])),
                          Text('₹${c.rate.toStringAsFixed(0)}',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.blue)),
                        ]),
                      ),
                    );
                  }).toList()),
      ),
    ]);
  }

  // ── STEP 2 — PAYMENT ────────────────────────────────────────
  Widget _payStep() => Column(
        key: const ValueKey(2),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _card(
              '🧾 Bill Details',
              Column(children: [
                _brow('Item Total', '₹${_cartTotal.toStringAsFixed(2)}'),
                _brow('Shipping (${_selCourier?.courierName ?? ''})', '₹${_shipping.toStringAsFixed(2)}'),
                const Divider(height: 20),
                _brow('Grand Total', '₹${_grand.toStringAsFixed(2)}', bold: true),
                const SizedBox(height: 6),
                if (_selCourier != null) _brow('Est. Delivery', '${_selCourier!.estimatedDays} days', valueColor: Colors.green),
                if (_selSlot != null) _brow('Time Slot', '${_selSlot!.label} • ${_selSlot!.timeRange}', valueColor: Colors.blue),
              ])),
          const SizedBox(height: 14),
          _card(
              '💳 Payment Method',
              Column(children: [
                _payOpt('prepaid', 'Pay Online', 'UPI / Card / Net Banking', Icons.payment, Colors.purple),
                const SizedBox(height: 10),
                _payOpt('cod', 'Cash on Delivery', _selCourier?.codAvailable == true ? 'Pay when order arrives' : 'Not available for selected courier',
                    Icons.money, Colors.green,
                    enabled: _selCourier?.codAvailable != false),
              ])),
          const SizedBox(height: 14),
          _card(
              '📍 Delivering To',
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.location_on, color: Colors.blue, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_nameCtrl.text, style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text('${_a1Ctrl.text}, ${_cityCtrl.text}, ${_stCtrl.text} – ${_pinCtrl.text}',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                    Text(_phoneCtrl.text, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                  ])),
                  TextButton(
                    onPressed: () => setState(() => _step = 0),
                    child: const Text('Edit', style: TextStyle(fontSize: 12)),
                  ),
                ],
              )),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.shade200),
            ),
            child: const Row(children: [
              Icon(Icons.verified_user, color: Colors.orange, size: 16),
              SizedBox(width: 8),
              Expanded(child: Text('Powered by Shiprocket — 25,000+ pincodes across India', style: TextStyle(fontSize: 11, color: Colors.orange))),
            ]),
          ),
        ],
      );

  // ── BOTTOM BAR ──────────────────────────────────────────────
  Widget _bottomBar() => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.07), blurRadius: 8, offset: const Offset(0, -2))],
        ),
        child: Row(children: [
          if (_step > 0) ...[
            Expanded(
                child: OutlinedButton(
              onPressed: () => setState(() => _step--),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                side: const BorderSide(color: Colors.blue),
                foregroundColor: Colors.blue,
              ),
              child: const Text('Back', style: TextStyle(fontSize: 15)),
            )),
            const SizedBox(width: 12),
          ],
          Expanded(
              flex: 2,
              child: ElevatedButton(
                onPressed: _placing ? null : _onNext,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 3,
                ),
                child: _placing
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(_step == 2 ? '  Place Order  →' : '  Continue  →', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              )),
        ]),
      );

  // ── HELPERS ─────────────────────────────────────────────────
  Widget _orderSummary() => Column(children: [
        ..._items.map((i) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Expanded(
                    child: Text('${i.name}  ×${i.quantity}', style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
                Text('${_currency}${((i.effectivePrice as num) * (i.quantity as num)).toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              ]),
            )),
        const Divider(height: 16),
        _brow('Subtotal', '${_currency}${_subtotal.toStringAsFixed(2)}'),
        if (_discountAmount > 0) _brow('Discount', '-${_currency}${_discountAmount.toStringAsFixed(2)}', valueColor: Colors.green),
        if (_gstAmount > 0) _brow('GST', '${_currency}${_gstAmount.toStringAsFixed(2)}'),
        if (_shipping > 0) _brow('Shipping', '${_currency}${_shipping.toStringAsFixed(2)}'),
        const Divider(height: 16),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('Total', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          Text('${_currency}${_grand.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.blue)),
        ]),
      ]);

  Widget _card(String title, Widget child) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 2))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 14),
          child,
        ]),
      );

  Widget _tf(TextEditingController c, String label, IconData icon, TextInputType type, {int? max}) => TextField(
        controller: c,
        keyboardType: type,
        maxLength: max,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon),
          counterText: '',
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          filled: true,
          fillColor: Colors.white,
        ),
      );

  Widget _brow(String l, String v, {bool bold = false, Color? valueColor}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(l,
              style: TextStyle(
                  fontSize: 13, color: bold ? Colors.black : Colors.grey.shade700, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
          Text(v,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: bold ? FontWeight.bold : FontWeight.w500,
                  color: valueColor ?? (bold ? Colors.black : Colors.grey.shade800))),
        ]),
      );

  Widget _payOpt(String val, String label, String sub, IconData icon, Color color, {bool enabled = true}) {
    final sel = _pay == val;
    return GestureDetector(
      onTap: enabled ? () => setState(() => _pay = val) : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: !enabled ? Colors.grey.shade100 : sel ? color.withOpacity(0.08) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: !enabled ? Colors.grey.shade300 : sel ? color : Colors.grey.shade300, width: sel ? 2 : 1),
        ),
        child: Row(children: [
          Radio<String>(
            value: val,
            groupValue: _pay,
            onChanged: enabled ? (_) => setState(() => _pay = val) : null,
            activeColor: color,
          ),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: enabled ? Colors.black : Colors.grey)),
            Text(sub, style: TextStyle(fontSize: 12, color: enabled ? Colors.grey.shade600 : Colors.grey.shade400)),
          ])),
          if (sel) Icon(Icons.check_circle, color: color, size: 20),
        ]),
      ),
    );
  }
}

// ================================================================
// 4. ORDER SUCCESS PAGE
// ================================================================
class OrderSuccessPage extends StatelessWidget {
  final OrderResult result;
  final DeliveryAddress address;
  final CourierOption courier;
  final TimeSlot slot;
  final double grandTotal;
  final String paymentMethod;
  final ShiprocketService service;

  const OrderSuccessPage({
    super.key,
    required this.result,
    required this.address,
    required this.courier,
    required this.slot,
    required this.grandTotal,
    required this.paymentMethod,
    required this.service,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFFF5F7FA),
        body: SafeArea(
            child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            const SizedBox(height: 20),
            Container(
              width: 110,
              height: 110,
              decoration:
                  BoxDecoration(color: Colors.green.shade50, shape: BoxShape.circle, border: Border.all(color: Colors.green.shade200, width: 3)),
              child: const Icon(Icons.check_circle, color: Colors.green, size: 64),
            ),
            const SizedBox(height: 20),
            const Text('Order Placed! 🎉', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('Order ID: ${result.orderId}', style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
            if (result.shipmentId.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('Shipment ID: ${result.shipmentId}', style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
            ],
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(8)),
              child: Text(result.message, style: const TextStyle(fontSize: 12, color: Colors.green)),
            ),
            const SizedBox(height: 24),
            _card(Column(children: [
              _row('Courier', courier.courierName),
              _row('Time Slot', '${slot.label}  •  ${slot.timeRange}'),
              _row('Payment', paymentMethod == 'cod' ? 'Cash on Delivery' : 'Online'),
              _row('Total', '₹${grandTotal.toStringAsFixed(2)}'),
              _row('Est. Days', '${courier.estimatedDays} days'),
            ])),
            const SizedBox(height: 14),
            _card(Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.location_on, color: Colors.blue, size: 20),
                const SizedBox(width: 10),
                Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(address.fullName, style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text('${address.addressLine1}, ${address.city}, ${address.state} – ${address.pincode}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                  Text(address.phone, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                ])),
              ],
            )),
            const SizedBox(height: 14),
            if (result.awbCode.isNotEmpty)
              SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => OrderTrackingPage(
                                  orderId: result.orderId,
                                  awbCode: result.awbCode,
                                  courierName: courier.courierName,
                                  service: service,
                                ))),
                    icon: const Icon(Icons.local_shipping),
                    label: const Text('Track My Order'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      side: const BorderSide(color: Colors.blue),
                      foregroundColor: Colors.blue,
                    ),
                  )),
            const SizedBox(height: 12),
            SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.popUntil(context, (r) => r.isFirst),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Continue Shopping', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                )),
            const SizedBox(height: 24),
          ]),
        )),
      );

  static Widget _card(Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 2))],
        ),
        child: child,
      );

  static Widget _row(String l, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(l, style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
          Text(v, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
      );
}

// ================================================================
// 5. ORDER TRACKING PAGE
// ================================================================
class OrderTrackingPage extends StatefulWidget {
  final String orderId, awbCode, courierName;
  final ShiprocketService service;
  const OrderTrackingPage({
    super.key,
    required this.orderId,
    required this.awbCode,
    required this.courierName,
    required this.service,
  });
  @override
  State<OrderTrackingPage> createState() => _OTPState();
}

class _OTPState extends State<OrderTrackingPage> {
  bool _loading = true;
  TrackingResult? _t;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() => _loading = true);
    final t = await widget.service.trackOrder(widget.awbCode);
    if (mounted) {
      setState(() {
        _t = t;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final events = _t?.events ?? [];
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('Track Order'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _fetch)],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _fetch,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [Colors.blue.shade400, Colors.blue.shade700]),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Icon(Icons.local_shipping, color: Colors.white, size: 32),
                      const SizedBox(height: 10),
                      Text(_t?.status ?? 'Processing', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                      if ((_t?.currentLocation ?? '').isNotEmpty)
                        Text('📍 ${_t!.currentLocation}', style: const TextStyle(color: Colors.white70, fontSize: 13)),
                      if ((_t?.estimatedDate ?? '').isNotEmpty)
                        Text('Est. ${_t!.estimatedDate}', style: const TextStyle(color: Colors.white70, fontSize: 13)),
                      const SizedBox(height: 8),
                      Text('Order: ${widget.orderId}', style: const TextStyle(color: Colors.white60, fontSize: 11)),
                      if (widget.awbCode.isNotEmpty) Text('AWB: ${widget.awbCode}', style: const TextStyle(color: Colors.white60, fontSize: 11)),
                    ]),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8)],
                    ),
                    child: Row(children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(color: Colors.blue.shade50, borderRadius: BorderRadius.circular(8)),
                        child: const Icon(Icons.local_shipping, color: Colors.blue, size: 24),
                      ),
                      const SizedBox(width: 12),
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('Courier Partner', style: TextStyle(fontSize: 11, color: Colors.grey)),
                        Text(widget.courierName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      ]),
                    ]),
                  ),
                  const SizedBox(height: 20),
                  const Text('Tracking Timeline', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8)],
                    ),
                    child: events.isEmpty
                        ? const Center(child: Padding(padding: EdgeInsets.all(16), child: Text('No events yet', style: TextStyle(color: Colors.grey))))
                        : Column(
                            children: List.generate(events.length, (i) {
                            final e = events[i];
                            final isLast = i == events.length - 1;
                            return IntrinsicHeight(
                                child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                    width: 32,
                                    child: Column(children: [
                                      Container(
                                        width: 24,
                                        height: 24,
                                        decoration: BoxDecoration(
                                            color: e.done ? Colors.green : Colors.grey.shade300,
                                            shape: BoxShape.circle,
                                            border: Border.all(color: e.done ? Colors.green : Colors.grey.shade400, width: 2)),
                                        child: Icon(e.done ? Icons.check : Icons.circle, size: 12, color: e.done ? Colors.white : Colors.grey.shade400),
                                      ),
                                      if (!isLast) Expanded(child: Container(width: 2, color: e.done ? Colors.green.shade200 : Colors.grey.shade200)),
                                    ])),
                                const SizedBox(width: 12),
                                Expanded(
                                    child: Padding(
                                  padding: EdgeInsets.only(bottom: isLast ? 0 : 20),
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text(e.status,
                                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: e.done ? Colors.black : Colors.grey)),
                                    if (e.location.isNotEmpty) Text(e.location, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                                    if (e.time.isNotEmpty) Text(e.time, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                                  ]),
                                )),
                              ],
                            ));
                          })),
                  ),
                  const SizedBox(height: 24),
                ]),
              ),
            ),
    );
  }
}